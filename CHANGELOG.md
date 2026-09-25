# Changelog

**English** · [简体中文](CHANGELOG.zh-CN.md)

`verify.bat` in the repository root is always the latest version. Every earlier version is kept in [`history/`](history/) for reference; they are not recommended for use.

## v14 · 2026-09-24 · latest

- **Files on one side only are no longer read.** A file that is missing in the target or extra in it gets that verdict whatever it contains, so it is reported straight away. Only files present on both sides with the same size are hashed. When a copy stopped half way, the missing half is skipped entirely.
- The `NOT READ` line before hashing now has two lines: how much was skipped, and how many files for each reason.

## v13

- **Size first.** A file present on both sides with two different sizes cannot be identical. It is reported as `[SIZE DIFFERS]` and neither side is read. The result table gains a `Different size` row.
- Skipped files are left out of the progress bars and the time estimate, so both still end at exactly 100%.
- A size that could not be read during the scan never takes this shortcut, so a scan error is not reported as a size difference.

## v12

- **Per-file progress.** Each side shows a new `File` row: percentage, bytes read, file size and time left for the file being read right now. A 50 GB file visibly moves instead of sitting at the same number for minutes.
- The reader publishes *(current file, bytes read of it)* as one value, so the name and the progress on screen always belong to the same file, even at the instant it switches to the next one.

## v11

- Better time estimate. Seconds per MiB now come straight from the speed measured over the last 3 seconds, the same speed that is shown on screen. The fixed cost per file only looks at the last ~15 seconds of files (v10: two minutes), and that cost is taken out of the window before the speed is worked out, so it is not counted twice.

## v10

- **Time estimate (ETA)**, modelled as a fixed cost per file plus a time per MiB. Live speed shown for each side.
- Same-disk detection goes down to the **physical disk** through WMI. Two partitions of one disk are no longer read in parallel. SUBST drives, spanned volumes and network servers are handled.

## v9

- The resume file is always called `verify_resume.txt`, whatever the `.bat` is called. Renaming the file or switching versions no longer loses saved progress.

## v8

- Fixed the blank line in the progress block.

## v7

- **Parallel workers removed.** Each folder is read by exactly one thread, file after file, which is what hard disks need. Two drives are read at the same time, one drive one folder after the other.
- Blank line between the two sides of the progress block; fixed an error in the progress bars.

## v6

- Four progress bars: files and bytes, for the source and for the target.

## v5

- Several worker threads hash files in parallel.
- **Resume**: progress is saved next to the `.bat`, so an interrupted run can be continued.

## v4

- **Nothing is written to disk.** The engine is compiled in memory instead of being extracted to `%TEMP%`. v3 left its temporary file behind when the window was closed with the X button.
- Runs in a loop: press any key for the next verification.

## v3

- **Rewritten on a PowerShell engine; results are now correct.** The v2 series was pure batch. It could not handle names containing `%` `!` `^` or a leading `;`, could not see hidden files or empty folders, failed on long paths, and stored `certutil` error text as if it were a hash. From v3 on, the `.bat` is only a launcher (this version extracted the engine to `%TEMP%`).

## v2 series

- **v2**: folders are chosen by dragging them into the window instead of a dialog.
- **v2-1**: the progress display no longer flickers.
- **v2-2**: the size of each file is shown.
- **v2-3**: two progress bars, by file count and by bytes.
- **v2-4**: progress updates more promptly.
- **v2-5**: progress bars snap to a fixed grid.

## v1

- First version. Source and target are picked with the Windows folder dialog, hashed with `Get-FileHash` into two sorted lists, and compared with `fc`.
