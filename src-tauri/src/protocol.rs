//! The `rbl://` scheme, which serves artwork straight to the webview.
//!
//! Artwork does not go through `invoke`: a JPEG is tens of kilobytes, the IPC
//! cap is 64 KB, and base64 in a JSON response would cost a main-thread decode
//! per row. An `<img src>` lets the webview fetch, decode and cache it off the
//! UI thread, which is the whole point.
//!
//! # Why it takes a track id and not a path
//!
//! The webview names a **track**, and the path is looked up in the index. A
//! scheme that accepted a path would hand anything running in the webview a
//! read of any file the app can reach. The id is resolved against the loaded
//! library, and the resulting path is checked to still sit under the share
//! root — belt and braces, because `ImagePath` comes from the database rather
//! than from us.

use std::sync::Arc;

use tauri::http::{Request, Response, StatusCode};

use rbl_app::media::ArtworkError;

use crate::state::AppState;

/// Artwork, by track id: `rbl://localhost/artwork/<id>`. The only kind of
/// request: audio used to be served here for an `<audio>` element, and
/// playback is the Rust engine now.
///
/// The kind is the first path segment, not the host. On Windows `WebView2` loads
/// no custom scheme, so the page asks for `http://rbl.localhost/…` and `wry`
/// hands it over as `rbl://localhost/…`; the host is `localhost` there, and
/// it is the same on macOS and Linux because the page asks for it there too.
const ARTWORK: &str = "artwork";

/// Refuses anything larger. Real artwork is tens of kilobytes; a file this big
/// is not album art and should not be read into memory to find out.
pub(crate) const MAX_BYTES: u64 = rbl_app::media::MAX_ARTWORK_BYTES;

/// Answers one `rbl://` request.
pub fn handle(state: &Arc<AppState>, request: &Request<Vec<u8>>) -> Response<Vec<u8>> {
    let Some(track_id) = artwork_id(request.uri().path()) else {
        return status(StatusCode::NOT_FOUND);
    };
    if track_id.is_empty() {
        return status(StatusCode::BAD_REQUEST);
    }

    if state.library().is_err() {
        // The last visible screen survives a cold start. Its files are
        // trusted app-owned copies keyed only by numeric id, never paths.
        return crate::screen_cache::cached_artwork(track_id)
            .map_or_else(|| status(StatusCode::SERVICE_UNAVAILABLE), image_response);
    }

    let bytes = match rbl_app::media::artwork_file(state, track_id) {
        Ok(bytes) => bytes,
        Err(ArtworkError::NotFound) => return status(StatusCode::NOT_FOUND),
        Err(ArtworkError::Refused) => return status(StatusCode::FORBIDDEN),
        Err(ArtworkError::TooLarge) => return status(StatusCode::PAYLOAD_TOO_LARGE),
    };

    Response::builder()
        .status(StatusCode::OK)
        .header("Content-Type", sniff_type(&bytes))
        .header("Access-Control-Allow-Origin", "*")
        // Artwork for a given track never changes without the library
        // reloading, and the frontend re-requests with a new generation then.
        .header("Cache-Control", "max-age=31536000, immutable")
        .body(bytes)
        .unwrap_or_else(|_| status(StatusCode::INTERNAL_SERVER_ERROR))
}

/// The track id in `/artwork/<id>`, or `None` for a path that asks for
/// anything else. Whatever follows the id is ignored.
fn artwork_id(path: &str) -> Option<&str> {
    let mut parts = path.trim_start_matches('/').split('/');
    (parts.next() == Some(ARTWORK)).then(|| parts.next().unwrap_or(""))
}

fn image_response(bytes: Vec<u8>) -> Response<Vec<u8>> {
    let content_type = sniff_type(&bytes);
    Response::builder().status(StatusCode::OK)
        .header("Content-Type", content_type)
        .header("Access-Control-Allow-Origin", "*")
        // This is a startup placeholder. The table remounts once the live
        // library is ready and must be allowed to fetch the authoritative art.
        .header("Cache-Control", "no-store")
        .body(bytes).unwrap_or_else(|_| status(StatusCode::INTERNAL_SERVER_ERROR))
}

/// The image type of artwork bytes, by magic number.
fn sniff_type(bytes: &[u8]) -> &'static str {
    if bytes.starts_with(b"\x89PNG") { "image/png" }
    else if bytes.starts_with(b"GIF8") { "image/gif" }
    else if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") { "image/webp" }
    else { "image/jpeg" }
}

/// Answers one request and hands the response to `respond`, whatever happens.
///
/// The responder is the whole reason this is a function rather than a closure
/// in `lib.rs`: `wry` gives the asynchronous scheme handler one, and a request
/// that never gets a response is a webview waiting for ever — an image that
/// never appears, a track that never starts. So a panic inside `handle`
/// answers 500 rather than escaping, and the panic is logged rather than lost.
pub fn serve<R>(state: &Arc<AppState>, request: &Request<Vec<u8>>, respond: R)
where
    R: FnOnce(Response<Vec<u8>>),
{
    serve_with(|| handle(state, request), respond);
}

/// The guard itself, with the answer as a closure so a test can make it panic.
fn serve_with<A, R>(answer: A, respond: R)
where
    A: FnOnce() -> Response<Vec<u8>>,
    R: FnOnce(Response<Vec<u8>>),
{
    let answered = std::panic::catch_unwind(std::panic::AssertUnwindSafe(answer));
    respond(answered.unwrap_or_else(|_| {
        tracing::error!("the rbl:// handler panicked");
        status(StatusCode::INTERNAL_SERVER_ERROR)
    }));
}

fn status(code: StatusCode) -> Response<Vec<u8>> {
    Response::builder()
        .status(code)
        .body(Vec::new())
        .unwrap_or_else(|_| Response::new(Vec::new()))
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// Counts how often the responder was called, which is the thing `wry`
    /// cares about: twice is a panic inside the webview, never is a request
    /// that hangs for ever.
    fn responses_of<A>(answer: A) -> Vec<Response<Vec<u8>>>
    where
        A: FnOnce() -> Response<Vec<u8>>,
    {
        let mut out = Vec::new();
        serve_with(answer, |response| out.push(response));
        out
    }

    #[test]
    fn an_answer_reaches_the_responder_once() {
        let out = responses_of(|| status(StatusCode::OK));
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].status(), StatusCode::OK);
    }

    #[test]
    fn a_panicking_answer_becomes_a_500_rather_than_a_request_that_never_returns() {
        // The whole point of the guard: `wry` hands the asynchronous handler a
        // responder, and an image whose request is never answered is a webview
        // waiting for ever.
        let out = responses_of(|| panic!("the analysis file was truncated"));
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].status(), StatusCode::INTERNAL_SERVER_ERROR);
    }

    #[test]
    fn a_request_before_the_library_is_loaded_is_answered_too() {
        // `serve` on the real handler, off the main thread in production: a
        // request that arrives during the load must come back, not hang.
        let state = Arc::new(AppState::new());
        let request = Request::builder()
            .uri("rbl://localhost/artwork/12345")
            .body(Vec::new())
            .unwrap();
        let mut out = Vec::new();
        serve(&state, &request, |response| out.push(response));
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].status(), StatusCode::SERVICE_UNAVAILABLE);
    }

    #[test]
    fn a_request_that_is_not_for_artwork_is_refused() {
        let state = Arc::new(AppState::new());
        for uri in ["rbl://localhost/etc/passwd", "rbl://etc/passwd", "rbl://localhost/"] {
            let request = Request::builder().uri(uri).body(Vec::new()).unwrap();
            let mut out = Vec::new();
            serve(&state, &request, |response| out.push(response));
            assert_eq!(out[0].status(), StatusCode::NOT_FOUND, "{uri}");
        }
    }

    #[test]
    fn the_track_id_is_read_from_the_path_whatever_the_host() {
        // macOS and Linux ask for `rbl://localhost/artwork/7`; Windows asks
        // for `http://rbl.localhost/artwork/7`, which `wry` hands over as
        // the same `rbl://localhost/artwork/7`.
        assert_eq!(artwork_id("/artwork/7"), Some("7"));
        assert_eq!(artwork_id("/artwork/7/anything"), Some("7"));
        assert_eq!(artwork_id("/artwork/"), Some(""));
        assert_eq!(artwork_id("/artwork"), Some(""));
        assert_eq!(artwork_id("/7"), None);
        assert_eq!(artwork_id("/"), None);
    }
}
