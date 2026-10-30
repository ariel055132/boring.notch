#!/usr/bin/env python3
"""Opt-in macOS Keychain rotation regression using only disposable fake data.

The fixture must live under ~/Library/Keychains because macOS does not enable
partition/integrity protection for a keychain created in /tmp. No login or
Claude credential is queried. The test removes its own search-list entry and
deletes only the UUID-named keychain it creates, including on assertion failure.
"""

import argparse
import json
from pathlib import Path
import plistlib
import re
import shlex
import subprocess
import sys
import tempfile
import uuid


SECURITY = "/usr/bin/security"


def run(arguments, check=True):
    result = subprocess.run(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=20, text=True)
    if check and result.returncode:
        # Raw child output is not needed to diagnose this fixture's failure.
        raise RuntimeError(f"{Path(arguments[0]).name} {arguments[1]} exited {result.returncode}")
    return result


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def search_list():
    return shlex.split(run([SECURITY, "list-keychains", "-d", "user"]).stdout)


def acl_summary(reply):
    matches = re.findall(r"^partition_hex=([0-9a-f]+)$", reply.stdout, re.MULTILINE)
    require(len(matches) == 1, "Fixture must contain exactly one real partition ACL")
    partitions = plistlib.loads(bytes.fromhex(matches[0]))["Partitions"]
    apps = re.findall(r"^trusted_app=(.*)$", reply.stdout, re.MULTILINE)
    return partitions, apps


def check_rotation():
    repo_root = Path(__file__).resolve().parents[1]
    fixture_source = repo_root / "Tests/Fixtures/claude-keychain-rotation-probe.c"
    fixture_id = str(uuid.uuid4())
    keychain_directory = Path.home() / "Library/Keychains"
    keychain_name = "boring-notch-rotation-fixture-" + fixture_id
    keychain = keychain_directory / (keychain_name + ".keychain")
    service = "BoringNotch-rotation-fixture-" + fixture_id
    # All passwords below are deliberately fake and belong only to this fixture.
    password = "fixture-only-keychain-password"
    before_value, after_value = "fixture-before", "fixture-after"
    baseline = search_list()
    results = {}
    created = False

    def owns_path(path):
        candidate = Path(path)
        return candidate.parent == keychain_directory and candidate.name.startswith(keychain_name + ".keychain")

    def remove_own_search_entry():
        current = search_list()
        filtered = [path for path in current if not owns_path(path)]
        if current != filtered:
            # Preserve the current list, not a stale copy from test startup.
            run([SECURITY, "list-keychains", "-d", "user", "-s", *filtered])

    with tempfile.TemporaryDirectory(prefix="boring-notch-keychain-rotation-") as build_directory:
        probe = Path(build_directory) / "probe"
        try:
            run(["/usr/bin/xcrun", "clang", "-Wno-deprecated-declarations", "-Wall", "-Wextra", "-Werror",
                 str(fixture_source), "-framework", "Security", "-framework", "CoreFoundation", "-o", str(probe)])
            run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "theboringteam.partition-fixture", str(probe)])
            signature = run(["/usr/bin/codesign", "--display", "--verbose=4", str(probe)])
            match = re.search(r"^CDHash=([a-f0-9]+)$", signature.stderr, re.MULTILINE)
            require(match is not None, "Signed fixture must have a code hash")
            cdhash = match.group(1)

            run([SECURITY, "create-keychain", "-p", password, str(keychain)])
            created = True
            remove_own_search_entry()
            run([SECURITY, "unlock-keychain", "-p", password, str(keychain)])
            run([SECURITY, "add-generic-password", "-a", "fixture", "-s", service, "-w", before_value,
                 "-T", str(probe), "-T", SECURITY, str(keychain)])
            run([SECURITY, "set-generic-password-partition-list", "-a", "fixture", "-s", service,
                 "-S", f"apple-tool:,cdhash:{cdhash}", "-k", password, str(keychain)])

            initial = run([str(probe), "read", str(keychain), before_value]).stdout
            require("read_status=0\n" in initial and "matches_expected=1\n" in initial,
                    "Native reader must initially read the authorized fake credential")
            results["native_before_rotation"] = True
            partitions_before, apps_before = acl_summary(run([str(probe), "acl", str(keychain), "unused"]))
            require(set(partitions_before) == {"apple-tool:", f"cdhash:{cdhash}"}, "Initial partition ACL is incorrect")
            require(str(probe) in apps_before and SECURITY in apps_before, "Both readers must initially be trusted")

            run([SECURITY, "add-generic-password", "-U", "-a", "fixture", "-s", service, "-w", after_value, str(keychain)])
            rotated = run([str(probe), "read", str(keychain), after_value]).stdout
            require("read_status=-25293\n" in rotated, "Native reader must fail authorization after partition reset")
            results["native_after_rotation_status"] = -25293
            partitions_after, apps_after = acl_summary(run([str(probe), "acl", str(keychain), "unused"]))
            require(partitions_after == ["apple-tool:"], "Rotation must replace the partition ACL with apple-tool")
            require(apps_before == apps_after, "Rotation must preserve the ordinary trusted-app ACL")
            results["partition_reset_with_trusted_apps_preserved"] = True
            cli = run([SECURITY, "find-generic-password", "-a", "fixture", "-s", service, "-w", str(keychain)])
            require(cli.stdout.rstrip("\n") == after_value, "System reader must retrieve the rotated fake credential")
            results["system_reader_after_rotation"] = True

            run([SECURITY, "lock-keychain", str(keychain)])
            locked = run([str(probe), "status", str(keychain), "unused"]).stdout
            require("keychain_status=0\n" in locked and "unlocked=0\n" in locked, "Preflight must detect a locked keychain")
            # Do not run the CLI reader while locked: it has no no-UI option.
            run([SECURITY, "unlock-keychain", "-p", password, str(keychain)])
            unlocked = run([str(probe), "status", str(keychain), "unused"]).stdout
            require("keychain_status=0\n" in unlocked and "unlocked=1\n" in unlocked, "Preflight must detect an unlocked keychain")
            results["locked_and_unlocked_preflight"] = True
        finally:
            if created:
                cleanup = run([SECURITY, "delete-keychain", str(keychain)], check=False)
                results["delete_keychain_status"] = cleanup.returncode
            # Creation/upgrade can leave an old-format file even on failure.
            # The UUID prefix was generated by this invocation, never supplied.
            for leftover in keychain_directory.glob(keychain_name + ".keychain*"):
                if leftover.is_file():
                    leftover.unlink()
            remove_own_search_entry()
            final = search_list()
            results["fixture_files_removed"] = not any(keychain_directory.glob(keychain_name + ".keychain*"))
            results["fixture_search_entry_removed"] = not any(owns_path(path) for path in final)
            # An external edit during the run is preserved rather than overwritten.
            results["search_list_unchanged"] = baseline == final
            print(json.dumps(results, indent=2))
            require(results["fixture_files_removed"] and results["fixture_search_entry_removed"], "Fixture cleanup failed")
            require(not created or results["delete_keychain_status"] == 0, "Keychain deletion failed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="Create and delete a disposable Keychain containing only fake credentials")
    args = parser.parse_args()
    if not args.run:
        parser.error("This integration check is opt-in; pass --run to create the disposable fixture.")
    if sys.platform != "darwin":
        parser.error("This integration check requires macOS.")
    check_rotation()
    print("Claude Keychain rotation regression passed.")


if __name__ == "__main__":
    main()
