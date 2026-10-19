"""Read Telegram-iOS Bazel BUILD files without Bazel.

BUILD files are Starlark, which is close enough to Python to execute with stub rule functions. Each rule call is
recorded with its keyword arguments; `glob()` returns its patterns unexpanded so the caller can expand them later.
"""
import os
import re
from dataclasses import dataclass, field


@dataclass
class Glob:
    include: list[str]
    exclude: list[str] = field(default_factory=list)

    def __add__(self, other):
        if isinstance(other, Glob):
            return Glob(self.include + other.include, self.exclude + other.exclude)
        return Glob(self.include + list(other), self.exclude)

    __radd__ = __add__


@dataclass
class Rule:
    kind: str
    label: str
    path: str
    attrs: dict

    @property
    def name(self) -> str:
        return self.attrs.get("module_name") or self.attrs["name"]


class _Names(dict):
    """Locals for exec: any unknown name (a loaded macro or constant) resolves to a stub."""

    def __init__(self, record):
        super().__init__()
        self.record = record

    def __missing__(self, key):
        return _Stub(key, self.record)


class _Stub:
    """A loaded macro, struct or constant: callable, with any attribute, and empty when used as a value."""

    def __init__(self, name, record):
        self.name, self.record = name, record

    def __call__(self, *args, **kwargs):
        if "name" in kwargs:
            self.record(self.name, kwargs)
        return _Stub(self.name, self.record)

    def __getattr__(self, attr):
        return _Stub(f"{self.name}.{attr}", self.record)

    def __iter__(self):
        return iter(())

    def __add__(self, other):
        return other

    __radd__ = __add__

    def __bool__(self):
        return False


def _select(mapping, **_):
    # Telegram selects on arm64 vs simulator and similar; take the default branch.
    for key in ("//conditions:default", "//build-system:ios_sim_arm64"):
        if key in mapping:
            return mapping[key]
    return next(iter(mapping.values()))


class Workspace:
    def __init__(self, root: str):
        self.root = root
        self._packages: dict[str, dict[str, Rule]] = {}

    def package(self, path: str) -> dict[str, Rule]:
        if path in self._packages:
            return self._packages[path]
        rules: dict[str, Rule] = {}
        build = os.path.join(self.root, path, "BUILD")
        if not os.path.exists(build):
            build = os.path.join(self.root, path, "BUILD.bazel")
        if os.path.exists(build):
            def record(kind, attrs):
                rules[attrs["name"]] = Rule(kind, f"//{path}:{attrs['name']}", path, attrs)

            names = _Names(record)
            names.update({
                "load": lambda *a, **k: None,
                "package_name": lambda: path,
                "glob": lambda include, exclude=[], allow_empty=True, **k: Glob(list(include), list(exclude)),
                "select": _select,
                "package": lambda **k: None,
                "exports_files": lambda *a, **k: None,
                "licenses": lambda *a, **k: None,
                "True": True,
                "False": False,
                "None": None,
            })
            source = open(build).read()
            exec(compile(source, build, "exec"), {"__builtins__": {"len": len, "list": list, "dict": dict, "str": str, "range": range, "enumerate": enumerate, "sorted": sorted}}, names)
        self._packages[path] = rules
        return rules

    def rule(self, label: str) -> Rule | None:
        label = label.lstrip("@")
        if label.startswith("//"):
            label = label[2:]
        path, _, name = label.partition(":")
        name = name or os.path.basename(path)
        return self.package(path).get(name)


def label_name(label: str) -> str:
    label = label.split("//", 1)[-1]
    path, _, name = label.partition(":")
    return name or os.path.basename(path)


def normalize_label(label: str) -> str:
    label = label.lstrip("@")
    if label.startswith("//"):
        label = label[2:]
    path, _, name = label.partition(":")
    return f"//{path}:{name or os.path.basename(path)}"


def compile_flags(copts: list[str]) -> tuple[list[str], list[str]]:
    """-D defines and -I header paths from a rule's copts."""
    defines, includes = [], []
    for opt in copts:
        if opt.startswith("-D"):
            defines.append(opt[2:])
        elif opt.startswith("-I"):
            includes.append(opt[2:])
    return defines, includes


SWIFT = {"swift_library"}
OBJC = {"objc_library", "cc_library"}
