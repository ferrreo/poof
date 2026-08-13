"""Test-root and fuzz-wiring release structure checks."""

from __future__ import annotations

from pathlib import Path
import re

from release_structure_io import bounded_tree_files, read_bounded_text


ROOT_IMPORT_RE = re.compile(
    r'^\s*_\s*=\s*@import\("([^"]+)"\);\s*$',
    re.MULTILINE,
)
FUZZ_FILE_RE = re.compile(
    r'^(?!\s*//)\s*(?:\.file\s*=|\.\{.*?\.file\s*=)\s*"([^"]+)"',
    re.MULTILINE,
)
FUZZ_TARGET_FILTER_RE = re.compile(
    r'\.file\s*=\s*"([^"]+)"\s*,\s*\.filter\s*=\s*"([^"]+)"\s*,',
    re.DOTALL,
)
FUZZ_IMPORT_BINDING_RE = re.compile(
    r'(?ms)^const\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*'
    r'@import\s*\(\s*"([^"]+\.zig)"\s*,?\s*\)\s*;'
)
FUZZ_FORCE_RE = re.compile(
    r'(?:_\s*=\s*@import\s*\(\s*"([^"]+\.zig)"\s*,?\s*\)\s*;|'
    r'_\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\s*;)'
)
FUZZ_SELECTOR_LINE_RE = re.compile(
    r'if \(eql\(target, "([^"]+)"\)\) return @import\('
)
FUZZ_DISPATCH_RE = re.compile(
    r'(?ms)^pub fn select\(comptime target: \[\]const u8\) type \{\n(.*?)^\}\s*'
)
FUZZ_HELPER_RE = re.compile(
    r'(?ms)^fn (select[0-9]+)\(comptime target: \[\]const u8\) \?type \{\n(.*?)^\}\s*'
)
ENTRY_ROOT_LINES = {
    "test.zig": (
        "std.testing.refAllDecls(ploof);",
        '_ = @import("tests/root.zig");',
        '_ = @import("fuzz/root.zig");',
    ),
    "tsan.zig": (
        '_ = @import("tests/unit/runtime_tsan_test.zig");',
    ),
}


def strip_zig_comments(text: str) -> str:
    text = strip_zig_multiline_strings(text)
    result: list[str] = []
    index = 0
    quote = ""
    block_depth = 0
    line_comment = False
    while index < len(text):
        pair = text[index:index + 2]
        character = text[index]
        if line_comment:
            if character == "\n":
                line_comment = False
                result.append(character)
            else:
                result.append(" ")
            index += 1
            continue
        if block_depth:
            if pair == "/*":
                block_depth += 1
                result.extend("  ")
                index += 2
            elif pair == "*/":
                block_depth -= 1
                result.extend("  ")
                index += 2
            else:
                result.append("\n" if character == "\n" else " ")
                index += 1
            continue
        if quote:
            result.append(character)
            index += 1
            if character == "\\" and index < len(text):
                result.append(text[index])
                index += 1
            elif character == quote:
                quote = ""
            continue
        if pair == "//":
            line_comment = True
            result.extend("  ")
            index += 2
        elif pair == "/*":
            block_depth = 1
            result.extend("  ")
            index += 2
        else:
            if character in {'"', "'"}:
                quote = character
            result.append(character)
            index += 1
    return "".join(result)


def strip_zig_multiline_strings(text: str) -> str:
    return re.sub(
        r"(?m)^[ \t]*\\\\.*$",
        lambda match: " " * len(match.group(0)),
        text,
    )


def check_test_roots(root: Path, errors: list[str]) -> None:
    roots = (
        ("tests/root.zig", "tests/unit", frozenset()),
        ("fuzz/root.zig", "fuzz", frozenset({"root.zig", "targets.zig"})),
    )
    for root_name, directory, excluded in roots:
        path = root / root_name
        text = read_bounded_text(path, root, errors)
        if text is None:
            continue
        active = strip_zig_comments(text)
        imports = set(ROOT_IMPORT_RE.findall(active))
        expected = {
            source.relative_to(path.parent).as_posix()
            for source in bounded_tree_files(
                root,
                directory,
                "test-root scan",
                errors,
                suffixes={".zig"},
            )
            if source.relative_to(root / directory).as_posix() not in excluded
        }
        missing = sorted(expected - imports)
        extra = sorted(imports - expected)
        if missing:
            errors.append(f"{root_name}: missing imports: {missing}")
        if extra:
            errors.append(f"{root_name}: unknown imports: {extra}")
        lines = [line.strip() for line in active.splitlines() if line.strip()]
        expected_lines = {f'_ = @import("{value}");' for value in expected}
        body = lines[1:-1] if len(lines) >= 2 else []
        if (not lines or lines[0] != "test {" or lines[-1] != "}" or
                len(body) != len(expected_lines) or set(body) != expected_lines):
            errors.append(f"{root_name}: root body is not canonical")
    for root_name, expected_body in ENTRY_ROOT_LINES.items():
        text = read_bounded_text(root / root_name, root, errors)
        if text is None:
            continue
        active = strip_zig_comments(text)
        match = re.search(
            r'(?ms)^test(?:\s+"[^"\n]*")?\s*\{\s*\n(.*?)^\}\s*$',
            active,
        )
        body = [] if match is None else [
            line.strip() for line in match.group(1).splitlines() if line.strip()
        ]
        if body != list(expected_body):
            errors.append(f"{root_name}: test root body is not canonical")


def check_fuzz_selector(root: Path, errors: list[str]) -> None:
    build_path = root / "build_fuzz.zig"
    selector_path = root / "fuzz/targets.zig"
    if not build_path.exists():
        return
    build_text = read_bounded_text(build_path, root, errors)
    selector_text = read_bounded_text(selector_path, root, errors)
    if build_text is None or selector_text is None:
        return
    active_build = strip_zig_comments(build_text)
    build_files = FUZZ_FILE_RE.findall(active_build)
    expected = set(build_files)
    selected = fuzz_selector_paths(strip_zig_comments(selector_text), errors)
    missing = sorted(expected - selected)
    extra = sorted(selected - expected)
    if missing:
        errors.append(f"fuzz/targets.zig: missing build targets: {missing}")
    if extra:
        errors.append(f"fuzz/targets.zig: unknown build targets: {extra}")
    targets = FUZZ_TARGET_FILTER_RE.findall(active_build)
    if len(targets) != len(build_files):
        errors.append("build_fuzz.zig: fuzz target file/filter wiring is not canonical")
        return
    for file_name, filter_name in targets:
        if not fuzz_filter_reachable(root, file_name, filter_name, errors):
            errors.append(
                f"build_fuzz.zig: filter is unreachable from {file_name}: {filter_name}"
            )


def fuzz_filter_reachable(
    root: Path,
    file_name: str,
    filter_name: str,
    errors: list[str],
) -> bool:
    pending = [root / file_name]
    visited: set[Path] = set()
    while pending:
        path = pending.pop()
        resolved = path.resolve()
        if resolved in visited:
            continue
        if not resolved.is_relative_to(root.resolve()) or len(visited) >= 4096:
            return False
        visited.add(resolved)
        text = read_bounded_text(resolved, root, errors)
        if text is None:
            return False
        active = strip_zig_comments(text)
        tests = zig_top_level_tests(active)
        if any(name is not None and filter_name in name for name, _ in tests):
            return True
        bindings = dict(FUZZ_IMPORT_BINDING_RE.findall(active))
        for imported in fuzz_forced_imports(tests, bindings):
            target = (resolved.parent / imported).resolve()
            if target.is_relative_to(root.resolve()):
                pending.append(target)
    return False


def fuzz_forced_imports(
    tests: list[tuple[str | None, str]],
    bindings: dict[str, str],
) -> set[str]:
    imports: set[str] = set()
    for name, body in tests:
        if name is not None:
            continue
        forced: set[str] = set()
        position = 0
        while position < len(body):
            match = FUZZ_FORCE_RE.match(body, position)
            if match is None:
                if body[position].isspace():
                    position += 1
                    continue
                break
            direct, binding = match.groups()
            if direct is not None:
                forced.add(direct)
            elif binding in bindings:
                forced.add(bindings[binding])
            position = match.end()
        else:
            imports.update(forced)
            continue
    return imports


def zig_top_level_tests(text: str) -> list[tuple[str | None, str]]:
    tests: list[tuple[str | None, str]] = []
    index = 0
    depth = 0
    quote = ""
    while index < len(text):
        character = text[index]
        if quote:
            if character == "\\":
                index += 2
                continue
            if character == quote:
                quote = ""
            index += 1
            continue
        if character in {'"', "'"}:
            quote = character
            index += 1
            continue
        if character == "{":
            depth += 1
            index += 1
            continue
        if character == "}":
            depth -= 1
            index += 1
            continue
        if (depth != 0 or not text.startswith("test", index) or
                (index > 0 and (text[index - 1].isalnum() or text[index - 1] == "_"))):
            index += 1
            continue
        cursor = index + len("test")
        if cursor < len(text) and (text[cursor].isalnum() or text[cursor] == "_"):
            index += 1
            continue
        while cursor < len(text) and text[cursor].isspace():
            cursor += 1
        name: str | None = None
        if cursor < len(text) and text[cursor] == '"':
            start = cursor + 1
            cursor = start
            while cursor < len(text) and text[cursor] != '"':
                cursor += 2 if text[cursor] == "\\" else 1
            if cursor >= len(text):
                return tests
            name = text[start:cursor]
            cursor += 1
            while cursor < len(text) and text[cursor].isspace():
                cursor += 1
        if cursor >= len(text) or text[cursor] != "{":
            index += 1
            continue
        end = zig_matching_brace(text, cursor)
        if end is None:
            return tests
        tests.append((name, text[cursor + 1:end]))
        index = end + 1
    return tests


def zig_matching_brace(text: str, start: int) -> int | None:
    depth = 1
    quote = ""
    index = start + 1
    while index < len(text):
        character = text[index]
        if quote:
            if character == "\\":
                index += 2
                continue
            if character == quote:
                quote = ""
        elif character in {'"', "'"}:
            quote = character
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return index
        index += 1
    return None


def fuzz_selector_paths(text: str, errors: list[str]) -> set[str]:
    dispatch = FUZZ_DISPATCH_RE.search(text)
    helpers = {name: body for name, body in FUZZ_HELPER_RE.findall(text)}
    if dispatch is None or not helpers:
        errors.append("fuzz/targets.zig: selector structure is not canonical")
        return set()
    names = sorted(helpers, key=lambda name: int(name.removeprefix("select")))
    expected_dispatch = " ".join(
        [f"if ({name}(target)) |selected| return selected;" for name in names] +
        ['@compileError("unknown fuzz target");']
    )
    actual_dispatch = " ".join(dispatch.group(1).split())
    if actual_dispatch != expected_dispatch:
        errors.append("fuzz/targets.zig: selector dispatch is not canonical")
    selected: set[str] = set()
    for name in names:
        lines = [line.strip() for line in helpers[name].splitlines() if line.strip()]
        index = 0
        while index + 2 < len(lines) and lines[index] != "return null;":
            branch = FUZZ_SELECTOR_LINE_RE.fullmatch(lines[index])
            imported = re.fullmatch(r'"\.\./([^"]+)",', lines[index + 1])
            if (branch is None or imported is None or lines[index + 2] != ");" or
                    branch.group(1) != imported.group(1)):
                errors.append(f"fuzz/targets.zig: {name} body is not canonical")
                return selected
            selected.add(branch.group(1))
            index += 3
        if index != len(lines) - 1 or lines[index] != "return null;":
            errors.append(f"fuzz/targets.zig: {name} body is not canonical")
            return selected
    return selected
