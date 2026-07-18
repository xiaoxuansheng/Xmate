"""
XMate - LibreTranslate model management helper.

Called by Dart via Process.run / Process.start.
All output is JSON lines — one JSON object per line.
Status lines have {"status":"..."} and are for progress reporting.
Result lines have {"ok":true,...} or {"ok":false,"error":"..."}.

Commands:
  list-installed              List installed language pairs
  list-available              List available (downloadable) language pairs
  install <from> <to>         Install a language pair model
  uninstall <from> <to>       Uninstall a language pair model
  index-update                Refresh the remote package index
"""
import json
import os
import shutil
import sys


def log(obj):
    """Write one JSON line to stdout."""
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def list_installed():
    try:
        from argostranslate.package import get_installed_packages
        pkgs = get_installed_packages()
        result = []
        for p in pkgs:
            # Compute disk size
            size = 0
            for root, dirs, files in os.walk(p.package_path):
                for f in files:
                    try:
                        size += os.path.getsize(os.path.join(root, f))
                    except OSError:
                        pass
            result.append({
                "from": p.from_code,
                "to": p.to_code,
                "version": p.package_version,
                "path": str(p.package_path),
                "sizeBytes": size,
            })
        log({"ok": True, "packages": result})
    except Exception as e:
        log({"ok": False, "error": str(e)})


def list_available():
    try:
        from argostranslate.package import update_package_index, get_available_packages

        log({"status": "Updating package index..."})
        update_package_index()

        available = get_available_packages()
        result = []
        for p in available:
            result.append({
                "from": p.from_code,
                "to": p.to_code,
                "version": p.package_version,
            })
        log({"ok": True, "packages": result})
    except Exception as e:
        log({"ok": False, "error": str(e)})


def install_package(from_code, to_code):
    try:
        from argostranslate.package import (
            update_package_index,
            get_available_packages,
            get_installed_packages,
            install_package_for_language_pair,
        )

        # Check if already installed
        installed = get_installed_packages()
        for p in installed:
            if p.from_code == from_code and p.to_code == to_code:
                log({"ok": True, "status": "already installed", "from": from_code, "to": to_code})
                return

        log({"status": f"Updating package index..."})
        update_package_index()

        log({"status": f"Downloading {from_code}->{to_code}..."})
        ok = install_package_for_language_pair(from_code, to_code)
        if ok:
            log({"ok": True, "status": "installed", "from": from_code, "to": to_code})
        else:
            log({"ok": False, "error": f"Package {from_code}->{to_code} not found in index"})
    except Exception as e:
        log({"ok": False, "error": str(e)})


def uninstall_package(from_code, to_code):
    try:
        from argostranslate.package import get_installed_packages

        installed = get_installed_packages()
        target = None
        for p in installed:
            if p.from_code == from_code and p.to_code == to_code:
                target = p
                break

        if target is None:
            log({"ok": False, "error": f"Package {from_code}->{to_code} is not installed"})
            return

        import shutil
        log({"status": f"Removing {from_code}->{to_code}..."})
        shutil.rmtree(target.package_path)

        # Clear the installed languages cache
        from argostranslate.translate import get_installed_languages
        get_installed_languages.cache_clear()

        log({"ok": True, "status": "uninstalled", "from": from_code, "to": to_code})
    except Exception as e:
        log({"ok": False, "error": str(e)})


def is_installed_check():
    """Quick check: is libretranslate importable?"""
    try:
        import libretranslate  # noqa: F401
        log({"ok": True, "installed": True})
    except ImportError:
        log({"ok": True, "installed": False})


def _find_bundled_dir():
    """Locate the bundled minisbd/ directory alongside this script."""
    candidates = [
        os.path.join(os.path.dirname(__file__), "minisbd"),
        os.path.join(os.path.dirname(__file__), "..", "minisbd"),
        os.path.join("scripts", "minisbd"),
    ]
    for d in candidates:
        if os.path.isdir(d):
            return d
    return None


def _inject_regex_fallback():
    """Monkey-patch MiniSBD sentencizer to fall back to regex splitting
    when the ONNX model file is unavailable for a given language.
    Uses Unicode sentence-boundary punctuation: . ! ? 。！？"""
    try:
        import re
        from argostranslate.sbd import MiniSBDSentencizer, ISentenceBoundaryDetectionModel

        _original_init = MiniSBDSentencizer.__init__

        def _patched_init(self, pkg):
            try:
                _original_init(self, pkg)
                # Test that the model works
                self.split_sentences("test.")
            except Exception:
                # Model unavailable — use regex fallback
                _RE_SENTENCE = re.compile(r'(?<=[.!?。！？\n])\s*')
                self.split_sentences = lambda text: [
                    s for s in _RE_SENTENCE.split(text) if s.strip()
                ] or [text]
                setattr(self, '__str__', lambda self: "RegexSentencizer (fallback)")

        MiniSBDSentencizer.__init__ = _patched_init
    except Exception:
        pass  # non-critical


def preload_sbd(lang_codes):
    """Ensure MiniSBD sentencizer models are cached for given language codes.

    Strategy:
    1. Inject regex fallback for any language (guaranteed to work)
    2. Copy from bundled scripts/minisbd/ (instant, offline)
    3. Fall back to GitHub download via minisbd package
    """
    try:
        _inject_regex_fallback()
        from minisbd import models as sbd_models

        bundled = _find_bundled_dir()
        if bundled:
            os.makedirs(sbd_models.cache_dir, exist_ok=True)
            for lang in lang_codes:
                if lang == 'auto':
                    continue
                fname = sbd_models.MODELS.get(lang)
                if fname is None:
                    continue
                dst = os.path.join(sbd_models.cache_dir, fname)
                if os.path.isfile(dst):
                    continue  # already cached
                src = os.path.join(bundled, fname)
                if os.path.isfile(src):
                    shutil.copy2(src, dst)
                    log({"status": f"SBD model copied: {lang} ({fname})"})

        # For any still-missing, try download
        existing = set(os.listdir(sbd_models.cache_dir)) if os.path.isdir(sbd_models.cache_dir) else set()
        for lang in lang_codes:
            if lang == 'auto':
                continue
            fname = sbd_models.MODELS.get(lang)
            if fname is None:
                continue
            if fname in existing:
                continue
            try:
                sbd_models.get_model_file(lang)
                log({"status": f"SBD model downloaded: {lang} ({fname})"})
            except Exception as e:
                log({"status": f"SBD model unavailable: {lang} — {e}"})

        log({"ok": True, "status": "sbd preload complete"})
    except Exception as e:
        log({"ok": False, "error": str(e)})


def main():
    if len(sys.argv) < 2:
        log({"ok": False, "error": "No command. Use: list-installed | list-available | install <from> <to> | uninstall <from> <to> | index-update | check-installed | preload-sbd <lang,...>"})
        return

    cmd = sys.argv[1]

    if cmd == "list-installed":
        list_installed()
    elif cmd == "list-available":
        list_available()
    elif cmd == "install":
        if len(sys.argv) < 4:
            log({"ok": False, "error": "Usage: install <from_code> <to_code>"})
            return
        install_package(sys.argv[2], sys.argv[3])
        # Also preload SBD models for this language pair
        preload_sbd([sys.argv[2], sys.argv[3]])
    elif cmd == "uninstall":
        if len(sys.argv) < 4:
            log({"ok": False, "error": "Usage: uninstall <from_code> <to_code>"})
            return
        uninstall_package(sys.argv[2], sys.argv[3])
    elif cmd == "index-update":
        try:
            from argostranslate.package import update_package_index
            update_package_index()
            log({"ok": True, "status": "index updated"})
        except Exception as e:
            log({"ok": False, "error": str(e)})
    elif cmd == "check-installed":
        is_installed_check()
    elif cmd == "preload-sbd":
        if len(sys.argv) < 3:
            log({"ok": False, "error": "Usage: preload-sbd <lang1,lang2,...>"})
            return
        preload_sbd(sys.argv[2].split(","))
    else:
        log({"ok": False, "error": f"Unknown command: {cmd}"})


if __name__ == "__main__":
    main()
