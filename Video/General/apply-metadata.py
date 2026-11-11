#!/usr/bin/env python3
"""Apply Jellyfin metadata, track names and a clean container title to MKV files.

Python port of apply-metadata.sh. The CLI, log lines and file effects match the
shell version; the internals do not. All XML and JSON work is done in-process
(xml.etree.ElementTree, json) instead of xmlstarlet and jq.

Track names follow the stream's actual codec: a name that still says TrueHD or
FLAC on an AAC stream is rewritten to AAC, and release-group junk is stripped
without deleting the codec word.

Requires:
    python3 (standard library only; no pip packages or virtualenv) plus
    mkvmerge, mkvpropedit, mkvextract and ffmpeg on PATH. The remux fallback
    uses ffmpeg; tag and track writes use MKVToolNix.

Usage:
    apply-metadata.py [--dry-run] [--debug] [--audit-log FILE] [FILE]

With no FILE every .mkv under the current directory is processed, excluding
extras. With FILE only that MKV is processed.

Exit codes: 0 success, 1 on a failed title/tag write or a usage error.
"""

from __future__ import annotations

import argparse
import atexit
import contextlib
import json
import os
import posixpath
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Sequence

# U+2013 EN DASH, the generated episode-title separator. Escape keeps source ASCII.
EN_DASH = "\u2013"

REQUIRED_TOOLS: tuple[str, ...] = ("mkvmerge", "mkvpropedit", "mkvextract", "ffmpeg")

# Filename suffixes that mark an extra. Tested against the basename, before .mkv.
EXTRAS_SUFFIXES: tuple[str, ...] = (
    "-trailer",
    "-behindthescenes",
    "-featurette",
    "-interview",
    "-scene",
    "-short",
    "-deleted",
    "-sample",
)

# Jellyfin extras directories. Any path component with one of these names is skipped.
EXTRAS_DIRS: frozenset[str] = frozenset(
    {
        "behind the scenes",
        "deleted scenes",
        "interviews",
        "scenes",
        "samples",
        "shorts",
        "featurettes",
        "clips",
        "other",
        "extras",
        "trailers",
        "theme-music",
        "backdrops",
    }
)

CLEAN_JUNK_PATTERNS: tuple[str, ...] = (
    "[Erai-raws]",
    "[SubsPlease]",
    "[Judas]",
    "[EMBER]",
    "[NC-Raws]",
    "[LowPower-Raws]",
    "Erai-raws",
    "SubsPlease",
    "ToonsHub",
    "Judas",
    "EMBER",
    "Anime Time",
    "HorribleSubs",
    "DeadFish",
    "AnimeRG",
    "NC-Raws",
    "LowPower-Raws",
    "Kirion",
    "Vodes",
    "Kawaiika-Raws",
    "Yameii",
    "AkihitoSubs",
    "CR WEB-DL",
    "HiDive",
    "Netflix",
    "AMZN",
    "Amazon",
    "Disney+",
    "Bilibili",
    "Ani-One",
)

# Audio codec names that may appear in a track title, longest first so E-AC-3
# wins over AC-3 and DTS-HD over DTS. A name that states the wrong codec is
# rewritten to the codec the stream actually carries (e.g. TrueHD on AAC).
AUDIO_CODEC_TOKENS: tuple[str, ...] = (
    "E-AC-3",
    "EAC3",
    "AC-3",
    "AC3",
    "DTS-HD",
    "DTS:X",
    "DTS",
    "TrueHD",
    "FLAC",
    "AAC",
    "MP3",
    "Opus",
    "Vorbis",
    "PCM",
    "LPCM",
    "MLP",
)

_CODEC_TOKEN_RE = re.compile(
    r"(?<![A-Za-z0-9])("
    + "|".join(re.escape(token) for token in sorted(AUDIO_CODEC_TOKENS, key=len, reverse=True))
    + r")(?![A-Za-z0-9])",
    re.IGNORECASE,
)

# Crunchyroll's "CR" release tag, as "_CR" or a standalone uppercase CR token.
_RELEASE_CR_RE = re.compile(r"(?<![A-Za-z0-9])CR(?![A-Za-z0-9])\s*(?:-\s*)?")

Json = dict[str, Any]

_TEMP_FILES: set[Path] = set()


# ---------------------------------------------------------------------------
# Temp file tracking (shell trap cleanup / atexit + signals)
# ---------------------------------------------------------------------------
def _track_temp(path: Path) -> Path:
    _TEMP_FILES.add(path)
    return path


def _discard_temp(path: Path) -> None:
    _TEMP_FILES.discard(path)
    with contextlib.suppress(OSError):
        path.unlink()


def _cleanup_temp_files() -> None:
    for path in list(_TEMP_FILES):
        _discard_temp(path)


def _abort(signum: int, _frame: object) -> None:
    _cleanup_temp_files()
    raise SystemExit(1)


atexit.register(_cleanup_temp_files)


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
class Logger:
    """Console logger matching the shell format, with optional audit file."""

    def __init__(self, audit_path: Path | None, debug_enabled: bool) -> None:
        self._audit = audit_path
        self._debug_enabled = debug_enabled

    def _emit(self, level: str, message: str, args: tuple[object, ...]) -> None:
        text = message % args if args else message
        print(f"[{level}] {text}", flush=True)
        if self._audit is not None:
            stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            try:
                with self._audit.open("a", encoding="utf-8") as handle:
                    handle.write(f"{stamp}  [{level}] {text}\n")
            except OSError as exc:
                print(f"Audit log write failed: {exc}", file=sys.stderr)

    def info(self, message: str, *args: object) -> None:
        """Log an INFO line."""
        self._emit("INFO", message, args)

    def warn(self, message: str, *args: object) -> None:
        """Log a WARN line."""
        self._emit("WARN", message, args)

    def error(self, message: str, *args: object) -> None:
        """Log an ERROR line."""
        self._emit("ERROR", message, args)

    def debug(self, message: str, *args: object) -> None:
        """Log a DEBUG line, only when --debug is set."""
        if self._debug_enabled:
            self._emit("DEBUG", message, args)


# ---------------------------------------------------------------------------
# External tools
# ---------------------------------------------------------------------------
def _run(args: Sequence[str]) -> subprocess.CompletedProcess[str]:
    """Run an external tool with an argument list and captured output."""
    return subprocess.run(
        list(args),
        check=False,
        capture_output=True,
        text=True,
        errors="replace",
    )


def probe(path: Path) -> Json | None:
    """Return mkvmerge's JSON identify output, or None if the file is unreadable."""
    result = _run(["mkvmerge", "-J", str(path)])
    if result.returncode != 0:
        return None
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    return data if isinstance(data, dict) else None


def _restore_mtime(path: Path, st: os.stat_result) -> None:
    with contextlib.suppress(OSError):
        os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns))


def remux_mkv(path: Path, st: os.stat_result, logger: Logger, reason: str, display: str) -> bool:
    """Stream-copy the file through ffmpeg. Replace it only on ffmpeg success."""
    logger.info("Remuxing (%s): %s", reason, display)
    tmp = _track_temp(path.with_suffix(".tmp"))
    result = _run(
        [
            "ffmpeg",
            "-y",
            "-i",
            str(path),
            "-map",
            "0",
            "-c",
            "copy",
            "-max_interleave_delta",
            "0",
            "-f",
            "matroska",
            str(tmp),
        ]
    )
    if result.returncode != 0:
        logger.error("ffmpeg remux failed (%d)", result.returncode)
        _discard_temp(tmp)
        return False
    os.replace(tmp, path)
    _discard_temp(tmp)
    _restore_mtime(path, st)
    return True


def _uid_needs_remux(data: Json) -> bool:
    """True when a track UID is missing, zero, or duplicated."""
    seen: set[object] = set()
    tracks = data.get("tracks")
    if not isinstance(tracks, list):
        return False
    for track in tracks:
        if not isinstance(track, dict):
            continue
        props = track.get("properties")
        props = props if isinstance(props, dict) else {}
        uid = props.get("uid")
        if uid is None or uid == 0:
            return True
        if uid in seen:
            return True
        seen.add(uid)
    return False


# ---------------------------------------------------------------------------
# NFO detection and parsing
# ---------------------------------------------------------------------------
def _base_name(path: Path) -> str:
    """Filename without a case-insensitive .mkv suffix."""
    name = path.name
    return name[:-4] if name.lower().endswith(".mkv") else name


def _find_nfo(directory: Path, base: str) -> Path | None:
    """First existing NFO from the shell script's candidate list."""
    sxxexx = re.search(r"S[0-9]{2}E[0-9]{2}", base)
    candidates = (
        f"{base}.nfo",
        f"{base.split(' - ', 1)[0]}.nfo",
        f"{base.split(' - Episode', 1)[0]}.nfo",
        f"{re.sub(r' - Episode.*', '', base)}.nfo",
        f"{sxxexx.group(0) if sxxexx else ''}.nfo",
        "episode.nfo",
        "movie.nfo",
    )
    for name in candidates:
        candidate = directory / name
        if candidate.is_file():
            return candidate
    return None


def _parse_xml_bytes(data: bytes) -> ET.Element | None:
    """Parse NFO bytes after the shell's BOM and leading-whitespace cleanup."""
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        return None
    text = "\n".join(line.lstrip() for line in text.split("\n"))
    try:
        return ET.fromstring(text)
    except ET.ParseError:
        return None


def _read_nfo(path: Path) -> ET.Element | None:
    try:
        data = path.read_bytes()
    except OSError:
        return None
    return _parse_xml_bytes(data)


def _child_text(root: ET.Element, name: str) -> str:
    """Text of all direct <name> children, joined like xmlstarlet's -v output.

    xmlstarlet prints one line per matched node and the shell then strips
    leading/trailing whitespace from every line, so multi-line plots keep their
    newlines but lose the surrounding spaces.
    """
    parts = ["".join(child.itertext()) for child in root.findall(name)]
    text = "\n".join(parts)
    return "\n".join(line.strip() for line in text.split("\n")).rstrip("\n")


def trim_trailing_dash(value: str) -> str:
    """Strip surrounding whitespace, then trailing hyphen/en-dash/em-dash runs."""
    value = value.strip()
    while value and value[-1] in "-" + EN_DASH + "\u2014":
        value = value[:-1].rstrip()
    return value


def _find_series_nfo(directory: Path) -> Path | None:
    try:
        entries = {entry.name.lower(): entry for entry in directory.iterdir() if entry.is_file()}
    except OSError:
        return None
    for name in ("series.nfo", "tvshow.nfo"):
        found = entries.get(name)
        if found is not None:
            return found
    return None


def resolve_series_root(start: Path) -> str:
    """Show name for an episode: nearest series NFO title, else a folder name.

    The start path is canonicalised before walking so a relative path cannot
    loop forever. The walk stops before the filesystem root, matching the shell.
    """
    try:
        original = start.resolve()
    except OSError:
        return start.name
    root = Path(original.anchor) if original.anchor else Path("/")
    current = original
    while current != root:
        nfo = _find_series_nfo(current)
        if nfo is not None:
            element = _read_nfo(nfo)
            if element is not None:
                title = _child_text(element, "title")
                if title:
                    return title
            return current.name
        current = current.parent
    parent = original.parent
    return parent.name or str(parent)


# ---------------------------------------------------------------------------
# Track-name cleaner
# ---------------------------------------------------------------------------
def clean_name(name: str, codec_label: str = "") -> str:
    """Strip release-group junk from a track name, then correct its codec token.

    The codec word is never treated as junk: it is replaced with the codec the
    stream actually carries, so a name that still says TrueHD or FLAC on an AAC
    stream becomes AAC. An empty codec_label leaves the codec word untouched.
    """
    for junk in CLEAN_JUNK_PATTERNS:
        name = name.replace(junk, "")
    name = name.replace("_CR", "")
    name = _RELEASE_CR_RE.sub("", name)
    name = name.replace("[]_", "").replace("[]", "")
    name = re.sub(r"\s+", " ", name).strip()
    name = name.lstrip(" _-")
    if codec_label:
        name = _CODEC_TOKEN_RE.sub(codec_label, name, count=1)
    return name.strip()


# ---------------------------------------------------------------------------
# Tag set construction
# ---------------------------------------------------------------------------
@dataclass
class Metadata:
    """Tag set and container title derived from one NFO."""

    kind: str
    container_title: str
    tags: dict[str, str]
    title: str
    plot: str
    showtitle: str = ""
    season: str = ""
    episode: str = ""
    etitle: str = ""


def build_metadata(root: ET.Element, base: str, directory: Path, logger: Logger) -> Metadata | None:
    """Classify an NFO and build its tag set. None means no tags should be applied."""
    kind = root.tag
    if kind not in ("movie", "episodedetails"):
        if _child_text(root, "showtitle") or _child_text(root, "season"):
            kind = "episodedetails"
        elif _child_text(root, "title"):
            kind = "movie"

    if kind == "movie":
        title = _child_text(root, "title") or base
        plot = _child_text(root, "plot")
        premiered = _child_text(root, "premiered")
        year = premiered[:4]
        container_title = f"{title} ({year})" if year else title
        return Metadata(
            kind="MOVIE",
            container_title=container_title,
            tags={
                "TITLE": title,
                "DESCRIPTION": plot,
                "DATE_RELEASED": year,
                "PREMIERED": premiered,
            },
            title=title,
            plot=plot,
        )

    if kind == "episodedetails":
        showtitle = _child_text(root, "showtitle") or resolve_series_root(directory)
        showtitle = trim_trailing_dash(showtitle)
        season = _child_text(root, "season")
        episode = _child_text(root, "episode")
        etitle = trim_trailing_dash(_child_text(root, "title") or f"Episode {episode}")
        plot = _child_text(root, "plot")
        aired = _child_text(root, "aired")
        year = aired[:4]
        if re.fullmatch(r"[0-9]+", season) and re.fullmatch(r"[0-9]+", episode):
            marker = f"S{int(season):02d}E{int(episode):02d}"
            container_title = f"{showtitle} {EN_DASH} {marker} {EN_DASH} {etitle}"
        else:
            logger.debug(
                "Season/episode not numeric ('%s'/'%s') -- omitting SxxEyy from title",
                season,
                episode,
            )
            container_title = f"{showtitle} {EN_DASH} {etitle}"
        return Metadata(
            kind="EPISODE",
            container_title=container_title,
            tags={
                "TITLE": etitle,
                "DESCRIPTION": plot,
                "SERIES": showtitle,
                "SHOW": showtitle,
                "SEASON": season,
                "EPISODE": episode,
                "DATE_RELEASED": year,
                "AIRED": aired,
            },
            title=etitle,
            plot=plot,
            showtitle=showtitle,
            season=season,
            episode=episode,
            etitle=etitle,
        )

    logger.warn("Unknown NFO root <%s> -- skipping tags", root.tag)
    return None


def build_tags_xml(meta: Metadata) -> str:
    """Serialise the Jellyfin tag set, plus the target-70 collection block for episodes."""
    root = ET.Element("Tags")
    _append_tag(root, meta.tags, None)
    if meta.kind == "EPISODE" and meta.showtitle:
        _append_tag(root, {"TITLE": meta.showtitle}, ("70", "COLLECTION"))
    ET.indent(root, space="  ")
    return ET.tostring(root, encoding="unicode")


def _append_tag(root: ET.Element, values: dict[str, str], target: tuple[str, str] | None) -> None:
    tag = ET.SubElement(root, "Tag")
    if target is not None:
        targets = ET.SubElement(tag, "Targets")
        ET.SubElement(targets, "TargetTypeValue").text = target[0]
        ET.SubElement(targets, "TargetType").text = target[1]
    for name, value in values.items():
        simple = ET.SubElement(tag, "Simple")
        ET.SubElement(simple, "Name").text = name
        ET.SubElement(simple, "String").text = value


# ---------------------------------------------------------------------------
# Existing tags and double-processing guard
# ---------------------------------------------------------------------------
def extract_tags(path: Path) -> ET.Element | None:
    """Parse the file's current tags, or None when it has none or they are unreadable."""
    handle, name = tempfile.mkstemp(prefix="apply-metadata-", suffix=".xml")
    os.close(handle)
    tmp = _track_temp(Path(name))
    try:
        result = _run(["mkvextract", str(path), "tags", str(tmp)])
        if result.returncode != 0 or not tmp.exists() or tmp.stat().st_size == 0:
            return None
        try:
            return ET.parse(tmp).getroot()
        except ET.ParseError:
            return None
    finally:
        _discard_temp(tmp)


def _simple_value(root: ET.Element, name: str) -> str:
    parts: list[str] = []
    for simple in root.iter("Simple"):
        if simple.findtext("Name") == name:
            value = simple.find("String")
            if value is not None:
                parts.append("".join(value.itertext()))
    return "".join(parts)


def _tag_title(root: ET.Element) -> str:
    """TITLE from Tag blocks that are not the target-70 collection block."""
    parts: list[str] = []
    for tag in root.iter("Tag"):
        targets = tag.find("Targets")
        if targets is not None:
            type_value = targets.find("TargetTypeValue")
            if type_value is not None and (type_value.text or "") == "70":
                continue
        for simple in tag.iter("Simple"):
            if simple.findtext("Name") == "TITLE":
                value = simple.find("String")
                if value is not None:
                    parts.append("".join(value.itertext()))
    return "".join(parts)


def already_processed(path: Path, meta: Metadata) -> bool:
    """True when the file already carries the tag values this run would write."""
    root = extract_tags(path)
    if root is None:
        return False
    if meta.kind == "EPISODE":
        return (
            _simple_value(root, "SERIES") == meta.showtitle
            and _simple_value(root, "SHOW") == meta.showtitle
            and _simple_value(root, "SEASON") == meta.season
            and _simple_value(root, "EPISODE") == meta.episode
            and _tag_title(root) == meta.etitle
        )
    return _tag_title(root) == meta.title and _simple_value(root, "DESCRIPTION") == meta.plot


# ---------------------------------------------------------------------------
# Per-file work
# ---------------------------------------------------------------------------
def _container_title(data: Json) -> str:
    container = data.get("container")
    if not isinstance(container, dict):
        return ""
    props = container.get("properties")
    if not isinstance(props, dict):
        return ""
    title = props.get("title")
    return title if isinstance(title, str) else ""


def rename_tracks(path: Path, data: Json, logger: Logger, display: str) -> None:
    """Rename every track in one mkvpropedit call. Failure is non-fatal."""
    args: list[str] = []
    tracks = data.get("tracks")
    if isinstance(tracks, list):
        for track in tracks:
            if not isinstance(track, dict):
                continue
            props = track.get("properties")
            props = props if isinstance(props, dict) else {}
            uid = props.get("uid")
            if uid is None:
                continue
            name = props.get("track_name")
            name = name if isinstance(name, str) else ""
            track_type = track.get("type")
            if track_type == "video":
                cleaned = "Video"
            elif track_type == "audio":
                codec = track.get("codec")
                cleaned = clean_name(name, codec.strip() if isinstance(codec, str) else "")
            else:
                cleaned = clean_name(name)
            args.extend(["--edit", f"track:={uid}", "--set", f"name={cleaned}"])
    if not args:
        return
    result = _run(["mkvpropedit", str(path), *args])
    if result.returncode != 0:
        logger.debug("Track rename failed (non-fatal): %s", display)


def write_tags(path: Path, meta: Metadata, logger: Logger, display: str) -> bool:
    """Write the tag XML next to the file and apply it. True means a write failed."""
    tags_path = _track_temp(path.parent / f"{_base_name(path)}.tags.tmp")
    try:
        tags_path.write_text(build_tags_xml(meta), encoding="utf-8")
        result = _run(["mkvpropedit", str(path), "--tags", f"all:{tags_path}"])
    finally:
        _discard_temp(tags_path)
    if result.returncode != 0:
        logger.error("mkvpropedit tag write failed: %s", display)
        return True
    return False


def process_file(path: Path, display: str, logger: Logger, dry_run: bool) -> bool:
    """Process one MKV. True means a container-title or tag write failed."""
    logger.info("Processing: %s", display)
    st = path.stat()

    data = probe(path)
    if data is None:
        if not remux_mkv(path, st, logger, "mkvmerge -J failed", display):
            return False
        data = probe(path)
        if data is None:
            return False

    if _uid_needs_remux(data):
        if not remux_mkv(path, st, logger, "UID sanity", display):
            return False
        data = probe(path)
        if data is None:
            return False

    base = _base_name(path)
    nfo = _find_nfo(path.parent, base)
    meta: Metadata | None = None
    if nfo is not None:
        element = _read_nfo(nfo)
        if element is None:
            # Keep the shell's path form: scan-mode paths carry their ./ prefix.
            nfo_display = posixpath.join(posixpath.dirname(display) or ".", nfo.name)
            logger.warn("Invalid XML in NFO -- ignoring: %s", nfo_display)
        else:
            meta = build_metadata(element, base, path.parent, logger)

    if meta is not None and already_processed(path, meta):
        logger.info("Skipping: Already processed.")
        return False

    failed = False
    if not dry_run:
        current_title = _container_title(data)
        new_title = meta.container_title if meta is not None else ""
        if current_title != new_title:
            result = _run(
                ["mkvpropedit", str(path), "--edit", "info", "--set", f"title={new_title}"]
            )
            if result.returncode == 0:
                logger.debug("Container title: '%s' -> '%s'", current_title, new_title)
            else:
                logger.error("mkvpropedit container title failed: %s", display)
                failed = True

        rename_tracks(path, data, logger, display)

        if meta is not None and write_tags(path, meta, logger, display):
            failed = True

        _restore_mtime(path, st)

    logger.info("Finished: %s", display)
    return failed


# ---------------------------------------------------------------------------
# Work list
# ---------------------------------------------------------------------------
def _has_extras_suffix(name: str) -> bool:
    stem = name[:-4] if name.lower().endswith(".mkv") else name
    lowered = stem.lower()
    return any(lowered.endswith(suffix) for suffix in EXTRAS_SUFFIXES)


def scan_mkvs() -> list[Path]:
    """Every non-extras MKV under the current directory, in stable order."""
    found: list[Path] = []
    for dirpath, dirnames, filenames in os.walk("."):
        dirnames[:] = sorted(name for name in dirnames if name.lower() not in EXTRAS_DIRS)
        for name in sorted(filenames):
            if not name.lower().endswith(".mkv"):
                continue
            if _has_extras_suffix(name):
                continue
            # find -type f does not follow symlinks; os.walk lists them as files.
            if os.path.islink(os.path.join(dirpath, name)):
                continue
            found.append(Path(dirpath, name))
    return found


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="apply-metadata.py",
        description="Apply Jellyfin metadata, track names and a container title to MKV files.",
        allow_abbrev=False,
    )
    parser.add_argument("--dry-run", action="store_true", help="probe and log without writing")
    parser.add_argument("--debug", action="store_true", help="emit DEBUG lines")
    parser.add_argument("--audit-log", metavar="FILE", help="append timestamped log lines to FILE")
    parser.add_argument("file", nargs="?", metavar="FILE", help="single MKV to process")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Entry point. Returns the process exit code."""
    args = _build_parser().parse_args(argv)

    missing = [tool for tool in REQUIRED_TOOLS if shutil.which(tool) is None]
    if missing:
        for tool in missing:
            print(f"Missing: {tool}")
        return 1

    audit_path = Path(args.audit_log) if args.audit_log else None
    if audit_path is not None:
        try:
            with audit_path.open("a", encoding="utf-8"):
                pass
        except OSError as exc:
            print(f"Cannot open audit log {audit_path}: {exc.strerror}", file=sys.stderr)
            return 1

    signal.signal(signal.SIGINT, _abort)
    signal.signal(signal.SIGTERM, _abort)

    logger = Logger(audit_path, args.debug)

    work: list[tuple[Path, str]]
    if args.file is not None:
        target = Path(args.file)
        if not target.is_file():
            print(f"Not a readable file: {args.file}", file=sys.stderr)
            return 1
        if not target.name.lower().endswith(".mkv"):
            print(f"Not an MKV: {args.file}", file=sys.stderr)
            return 1
        logger.info("Single file: %s", args.file)
        work = [(target, args.file)]
    else:
        logger.info("Scanning for MKV files...")
        work = [(path, f"./{path.as_posix()}") for path in scan_mkvs()]

    had_error = False
    for path, display in work:
        try:
            if process_file(path, display, logger, args.dry_run):
                had_error = True
        except OSError as exc:
            logger.error("Failed to process %s: %s", display, exc)
            had_error = True

    if had_error:
        logger.error("Unified metadata run complete with errors.")
        return 1
    logger.info("Unified metadata run complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
