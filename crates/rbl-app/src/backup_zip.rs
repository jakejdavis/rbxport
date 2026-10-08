//! Standard ZIP snapshots: parallel per-file compression, then raw assembly.
use std::{
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
};
use zip::{write::SimpleFileOptions, ZipArchive, ZipWriter};

pub fn compressed_path(path: &Path) -> PathBuf {
    let mut name = path.as_os_str().to_os_string();
    name.push(".zip");
    name.into()
}

pub fn compress_file(
    source: &Path,
    target: &Path,
    progress: &mut dyn FnMut(u64) -> io::Result<()>,
) -> io::Result<u64> {
    progress(0)?;
    let meta = fs::symlink_metadata(source)?;
    if !meta.is_file() || meta.file_type().is_symlink() {
        return Err(io::Error::other("Expected a regular backup file"));
    }
    let output = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(compressed_path(target))?;
    let mut zip = ZipWriter::new(output);
    zip.start_file(
        "data",
        SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated)
            .compression_level(Some(9))
            .large_file(meta.len() >= u64::from(u32::MAX)),
    )?;
    let mut source = fs::File::open(source)?;
    let mut buffer = vec![0; 1024 * 1024];
    let mut copied = 0;
    loop {
        progress(0)?;
        let count = source.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        zip.write_all(&buffer[..count])?;
        copied += count as u64;
        progress(count as u64)?;
    }
    zip.finish()?.sync_all()?;
    Ok(copied)
}

pub fn assemble(
    root: &Path,
    target: &Path,
    check: &mut dyn FnMut() -> io::Result<()>,
) -> io::Result<()> {
    let output = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(target)?;
    let mut zip = ZipWriter::new(output);
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        check()?;
        for entry in fs::read_dir(&directory)? {
            check()?;
            let path = entry?.path();
            let meta = fs::symlink_metadata(&path)?;
            if meta.file_type().is_symlink() {
                return Err(io::Error::other("Unexpected symbolic link"));
            }
            let relative = path
                .strip_prefix(root)
                .map_err(io::Error::other)?
                .to_string_lossy()
                .replace('\\', "/");
            if meta.is_dir() {
                zip.add_directory(format!("{relative}/"), SimpleFileOptions::default())?;
                pending.push(path);
            } else if relative == rbl_backup::manifest::NAME
                || relative == rbl_backup::summary::NAME
                || relative == crate::backup_restore_scripts::SHELL_NAME
                || relative == crate::backup_restore_scripts::POWERSHELL_NAME
            {
                let permissions = if relative == crate::backup_restore_scripts::SHELL_NAME {
                    0o755
                } else {
                    0o644
                };
                zip.start_file(
                    relative,
                    SimpleFileOptions::default()
                        .compression_method(zip::CompressionMethod::Deflated)
                        .compression_level(Some(9))
                        .unix_permissions(permissions),
                )?;
                zip.write_all(&fs::read(&path)?)?;
            } else {
                let name = relative
                    .strip_suffix(".zip")
                    .ok_or_else(|| io::Error::other("Uncompressed backup entry"))?;
                let mut entry = ZipArchive::new(fs::File::open(&path)?)?;
                zip.raw_copy_file_rename(entry.by_index(0)?, name)?;
            }
        }
    }
    zip.finish()?.sync_all()
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    #[test]
    fn compression_assembles_a_standard_zip_with_exact_bytes() {
        let dir = tempfile::tempdir().unwrap();
        let stage = dir.path().join("stage");
        fs::create_dir_all(stage.join("analysis/empty")).unwrap();
        let source = dir.path().join("source");
        let data = vec![7; 1024 * 1024];
        fs::write(&source, &data).unwrap();
        compress_file(&source, &stage.join("analysis/ANLZ.DAT"), &mut |_| Ok(())).unwrap();
        fs::write(stage.join("manifest.json"), b"{}").unwrap();
        fs::write(stage.join("summary.json"), b"{\"version\":1}").unwrap();
        let archive = dir.path().join("backup.zip");
        assemble(&stage, &archive, &mut || Ok(())).unwrap();
        assert!(fs::metadata(&archive).unwrap().len() < 10_000);
        let mut zip = ZipArchive::new(fs::File::open(&archive).unwrap()).unwrap();
        let mut read = |name: &str| {
            let mut bytes = Vec::new();
            zip.by_name(name).unwrap().read_to_end(&mut bytes).unwrap();
            bytes
        };
        assert_eq!(read("analysis/ANLZ.DAT"), data);
        assert_eq!(read("summary.json"), b"{\"version\":1}");
        assert!(zip.by_name("analysis/empty/").unwrap().is_dir());
    }

    #[test]
    fn compression_can_be_cancelled_between_chunks() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("source");
        fs::write(&source, vec![8; 3 * 1024 * 1024]).unwrap();
        let result = compress_file(&source, &dir.path().join("target"), &mut |bytes| {
            if bytes > 0 {
                Err(io::Error::new(io::ErrorKind::Interrupted, "cancelled"))
            } else {
                Ok(())
            }
        });
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::Interrupted);
        assert_eq!(fs::metadata(source).unwrap().len(), 3 * 1024 * 1024);
    }
}
