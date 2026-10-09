//! Making a library when there is none: what would be made, where, and doing it.
//!
//! Planned again at the moment of creating, never trusted from startup: a library that has
//! appeared since (rekordbox installed while the question was open) is loaded, never replaced.

use std::path::{Path, PathBuf};

use rbl_db::new_library::Plan;

use crate::error::{AppError, AppResult, ErrorKind};

/// Where a new library would go.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewLibraryPlan {
    /// The database that would be made.
    pub master_db: PathBuf,
    /// Whether the folder may be chosen. Not when an `options.json` already names the database:
    /// that file, rekordbox's, is never rewritten.
    pub can_choose_location: bool,
}

fn not_found(e: impl std::fmt::Display) -> AppError {
    AppError::new(ErrorKind::NotFound, "Could not find where the library should go.").with_detail(e.to_string())
}

fn describe(plan: Option<Plan>) -> Option<NewLibraryPlan> {
    plan.map(|p| NewLibraryPlan { can_choose_location: p.options_json.is_some(), master_db: p.master_db })
}

/// What making a library now would do, or `None` when there is a database already.
pub fn plan() -> AppResult<Option<NewLibraryPlan>> {
    rbl_db::new_library::plan().map(describe).map_err(not_found)
}

/// The same, for a library to go in `folder` if the options file leaves the choice open.
pub fn plan_in(folder: &Path) -> AppResult<Option<NewLibraryPlan>> {
    rbl_db::new_library::plan_in(folder).map(describe).map_err(not_found)
}

/// Makes the library. `folder` is honoured only when the options file leaves the place open
/// (see [`NewLibraryPlan::can_choose_location`]); otherwise the library goes where it says.
/// Returns the database made, or `None` when one is there already and nothing was written.
pub fn create(folder: Option<&Path>) -> AppResult<Option<PathBuf>> {
    make(rbl_db::new_library::plan().map_err(not_found)?, rbl_db::new_library::plan_in, folder)
}

/// [`create`] over a given first plan and way to plan again in a folder.
pub fn make(
    plan: Option<Plan>,
    plan_in: impl FnOnce(&Path) -> rbl_db::Result<Option<Plan>>,
    folder: Option<&Path>,
) -> AppResult<Option<PathBuf>> {
    let Some(mut plan) = plan else { return Ok(None) };
    if let (Some(_), Some(folder)) = (&plan.options_json, folder) {
        if !folder.is_absolute() {
            return Err(AppError::new(ErrorKind::Malformed, "Choose a full folder path for the library."));
        }
        std::fs::create_dir_all(folder).map_err(|e| {
            AppError::internal(format!("The library folder could not be made: {e}")).with_detail(e.to_string())
        })?;
        plan = plan_in(folder)
            .map_err(not_found)?
            .ok_or_else(|| AppError::new(ErrorKind::Malformed, "There is a library in that folder already."))?;
    }
    let made = rbl_db::new_library::create(&plan).map_err(|e| {
        AppError::new(ErrorKind::Internal, format!("Could not make the library: {e}")).with_detail(e.to_string())
    })?;
    tracing::info!(path = %made.master_db.display(), "made a new library");
    Ok(Some(made.master_db))
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    fn fresh() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let root = tempfile::tempdir().unwrap();
        let options = root.path().join("agent/storage/options.json");
        let library = root.path().join("Pioneer/rekordbox");
        (root, options, library)
    }

    #[test]
    fn a_plan_with_no_options_file_lets_the_folder_be_chosen() {
        let (_root, options, library) = fresh();
        let plan = describe(rbl_db::new_library::plan_at(&options, &library).unwrap()).unwrap();
        assert!(plan.can_choose_location);
        assert_eq!(plan.master_db, library.join("master.db"));
    }

    #[test]
    fn a_chosen_folder_gets_the_library_and_the_options_file_names_it() {
        let (root, options, library) = fresh();
        let chosen = root.path().join("Music/My Library");
        let first = rbl_db::new_library::plan_at(&options, &library).unwrap();
        let made = make(first, |f| rbl_db::new_library::plan_at(&options, f), Some(&chosen)).unwrap().unwrap();
        assert_eq!(made, chosen.join("master.db"));
        assert!(made.is_file());
        assert!(chosen.join("share/PIONEER/USBANLZ").is_dir());
        assert!(!library.exists(), "the default place is left alone");
        let found = rbl_db::detect_from(&options).unwrap();
        assert_eq!(found.master_db, made);
    }

    #[test]
    fn an_options_file_that_names_the_database_decides_the_place() {
        let (root, options, library) = fresh();
        let first = rbl_db::new_library::plan_at(&options, &library).unwrap();
        make(first, |f| rbl_db::new_library::plan_at(&options, f), None).unwrap().unwrap();
        // The options file now names `library/master.db`; remove the database and ask again.
        std::fs::remove_file(library.join("master.db")).unwrap();
        let again = rbl_db::new_library::plan_at(&options, &library).unwrap();
        assert!(!describe(again.clone()).unwrap().can_choose_location);
        let elsewhere = root.path().join("elsewhere");
        let made = make(again, |f| rbl_db::new_library::plan_at(&options, f), Some(&elsewhere)).unwrap().unwrap();
        assert_eq!(made, library.join("master.db"), "the chosen folder is not used");
        assert!(!elsewhere.exists());
    }

    #[test]
    fn a_library_that_is_there_is_never_replaced() {
        let (_root, options, library) = fresh();
        let first = rbl_db::new_library::plan_at(&options, &library).unwrap();
        make(first, |f| rbl_db::new_library::plan_at(&options, f), None).unwrap();
        let before = std::fs::read(library.join("master.db")).unwrap();
        let none = rbl_db::new_library::plan_at(&options, &library).unwrap();
        assert!(make(none, |f| rbl_db::new_library::plan_at(&options, f), None).unwrap().is_none());
        assert_eq!(std::fs::read(library.join("master.db")).unwrap(), before);
    }

    #[test]
    fn a_relative_folder_is_refused() {
        let (_root, options, library) = fresh();
        let first = rbl_db::new_library::plan_at(&options, &library).unwrap();
        let err = make(first, |f| rbl_db::new_library::plan_at(&options, f), Some(Path::new("relative/dir"))).unwrap_err();
        assert_eq!(err.kind, ErrorKind::Malformed);
    }
}
