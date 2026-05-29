

\# Filename: spec\_setairdate.md

\# Description: Specification document for setairdate.sh video timestamp synchronization utility



\# 1. Purpose and Scope

\- \*\*Primary Function\*\*: Synchronizes timestamps between TV episode video files (MKV/MP4) and their NFO metadata files based on air dates.

\- \*\*Scope\*\*:

&#x20; - Input: MKV/MP4 videos in current directory (recursive search)

&#x20; - Ignore files that match \*-trailer.\*

&#x20; - Output: Updated file timestamps for matching video/NFO pairs

&#x20; - Metadata Standard: Kodi <episodedetails> with <aired> tag



\# 2. Design Principles

\- \*\*Robust Parsing\*\*: Handle malformed XML and edge cases without crashing.

\- \*\*Idempotency\*\*: Safe to run multiple times on the same files.

\- \*\*Safety\*\*: Reject suspiciously future-dated metadata; use fallback mechanisms.



\# 3. Inputs and Outputs



\## Inputs

\- `video` files: MKV/MP4 video files in current directory (recursive)

\- `nfo` files: Matching `<basename>.nfo` for each video

\- Air dates: From <aired> tag in NFO XML or file/folder timestamps if missing

\- Target date: Midday (12:00:00) on resolved air date



\## Outputs

\- Updated mtime of both video and NFO files to the resolved target date

\- Zero changes for:

&#x20; - Missing NFO files

&#x20; - Future-dated (>30 days) metadata

&#x20; - Suspiciously future-dated file timestamps (falls back to folder birth time)



\# 4. Algorithm



\## Main Processing Loop

1\. For each video file in directory tree:

&#x20;  a. Extract base name without extension (`base`)

&#x20;  b. Construct NFO path: `${base}.nfo`

&#x20;  c. \*\*Edge Case - Filename safety\*\*:

&#x20;     - Uses `-print0` (find) and `IFS=$'\\n\\t'` to handle filenames with control characters or newlines safely

&#x20;     - XML parsing uses `xmlstarlet` which can parse most malformed documents, not just strictly valid ones



2\. \*\*Metadata Extraction from NFO\*\*:

&#x20;  a. Try <aired> tag: Parse YYYY-MM-DD format

&#x20;     b. \*\*Edge Case - Date safety\*\*:

&#x20;        - Reject future-dated dates (>30 days) as suspiciously corrupted metadata

&#x20;        - Accept reasonable air dates (within 30 days of current date)

&#x20;     c. If no <aired> or invalid:

&#x20;        - Use earliest mtime between video and NFO files

&#x20;        - \*\*Edge Case - File safety\*\*:

&#x20;            - Reject file timestamps more than 30 days in the future as suspiciously corrupted metadata



3\. \*\*Timestamp Synchronization\*\*:

&#x20;  a. For valid target date: Set both video and NFO to midday (12:00) on that day

&#x20;  b. Reject updates if target date is too far in the future (>30 days)



4\. \*\*Fallback Mechanisms\*\*:

&#x20;  a. No NFO -> Skip

&#x20;  b. Suspiciously dated files -> Use folder birth time/mtime as fallback



\# 5. Edge Cases Handled



\## Filename Handling

\- Uses `-print0` with `find` to handle filenames containing newlines or control characters safely

\- XML parsing using `xmlstarlet` can tolerate many malformed documents (not just valid XML)



\## Metadata Integrity

\- Rejects air dates more than 30 days in the future as corrupted metadata

\- Rejects file timestamps more than 30 days in the future as corrupted data



\## File Existence and Type

\- Only processes existing video files (MKV/MP4) with matching NFO files

\- Skips directories without NFO files



\# 6. Error Handling



\## Error Codes

\- \*\*Processed\*\*: Successfully updated files (counted)

\- \*\*Skipped\*\*: No NFO found or file/folder not accessible (counted separately)

\- \*\*Errors\*\*: Failed timestamp updates, could continue on failure if `set -e` is unset



\## Graceful Failure

\- Uses `set +uo` to reset any inherited shell options before processing

\- Detailed error messages include affected files and reasons for failures



\# 7. Requirements



\## Dependency Requirements

\- xmlstarlet: For XML parsing (must be installed)

\- bash ≥ 4.0: Required features like `IFS=$'\\n\\t'` and process substitution

\- GNU coreutils or macOS equivalents:

&#x20;  - stat -c format: To read mtime as epoch integer

&#x20;  - date -d support: To handle future dates

&#x20;  - touch -d/-t options: For setting timestamps



\# 8. Usage Example



```bash

\# Main execution (no debug)

./setairdate.sh



\# Debug mode with verbose output

./setairdate.sh --debug



