#!/usr/bin/env python3
"""Create/reuse a private, persistent signing identity for local Boring Notch builds.

No Claude credentials, existing ACLs, or system trust settings are changed.
Only the public certificate fingerprint is written into the ignored xcconfig.
"""

import fcntl
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


IDENTITY_NAME = "Boring Notch Local Signing"
REPO = Path(__file__).resolve().parent.parent
CONFIG = REPO / "Configuration/LocalSigning.xcconfig"
KEYCHAIN = Path.home() / "Library/Keychains/login.keychain-db"


def run(*args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "Command failed: " + args[0])
    return result.stdout


def signature(path):
    result = subprocess.run(
        ["/usr/bin/codesign", "-d", "--verbose=3", "-r-", str(path)],
        text=True, capture_output=True, check=True,
    )
    output = result.stdout + result.stderr
    requirement = re.search(r"^(?:#\s*)?designated => (.+)$", output, re.MULTILINE)
    digest = re.search(r"^CDHash=(\w+)$", output, re.MULTILINE)
    if not requirement or not digest:
        raise RuntimeError("Could not inspect the signing identity's designated requirement:\n" + output)
    return requirement.group(1), digest.group(1)


def main():
    os.umask(0o077)
    if not KEYCHAIN.exists():
        raise RuntimeError("The login Keychain was not found")
    with tempfile.TemporaryDirectory(prefix="boring-notch-signing-") as temporary:
        directory = Path(temporary)
        pem = directory / "certificate.pem"
        der = directory / "certificate.der"
        existing = subprocess.run(
            ["/usr/bin/security", "find-certificate", "-c", IDENTITY_NAME, "-p", str(KEYCHAIN)],
            text=True, capture_output=True,
        )
        if existing.returncode == 0:
            pem.write_text(existing.stdout)
        else:
            # Do not create a replacement identity if the recorded one is missing.
            # A replacement would invalidate the user's existing app authorizations.
            if CONFIG.exists():
                raise RuntimeError("Local signing is configured but its certificate is unavailable; restore that identity instead of replacing it")
            if "could not be found" not in existing.stderr.lower():
                raise RuntimeError(existing.stderr.strip() or "Could not inspect the login Keychain")
            openssl_config = directory / "openssl.cnf"
            openssl_config.write_text(
                "[req]\nprompt = no\ndistinguished_name = subject\nx509_extensions = signing\n"
                "[subject]\nCN = " + IDENTITY_NAME + "\n"
                "[signing]\nbasicConstraints = critical,CA:false\n"
                "keyUsage = critical,digitalSignature\nextendedKeyUsage = critical,codeSigning\n"
            )
            private_key = directory / "private-key.pem"
            package = directory / "identity.pem"
            run("/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:3072",
                "-nodes", "-sha256", "-days", "3650", "-config", str(openssl_config),
                "-keyout", str(private_key), "-out", str(pem))
            # The temporary directory is 0700; private files are 0600 and removed
            # immediately after import. No password or private key is logged.
            # A PEM sequence avoids putting an import password on the command
            # line and avoids the platform's empty-password PKCS#12 ambiguity.
            package.write_bytes(pem.read_bytes() + private_key.read_bytes())
            run("/usr/bin/security", "import", str(package), "-k", str(KEYCHAIN),
                "-f", "pemseq", "-t", "agg", "-x", "-T", "/usr/bin/codesign")
            private_key.unlink()
            package.unlink()
            print("Created the dedicated local signing identity in the login Keychain.")

        run("/usr/bin/openssl", "x509", "-in", str(pem), "-outform", "DER", "-out", str(der))
        fingerprint = hashlib.sha1(der.read_bytes()).hexdigest().upper()
        if CONFIG.exists():
            configured = re.search(r"^BORING_NOTCH_CODE_SIGN_IDENTITY\s*=\s*([A-Fa-f0-9]{40})\s*$",
                                   CONFIG.read_text(), re.MULTILINE)
            if not configured or configured.group(1).upper() != fingerprint:
                raise RuntimeError("The existing local configuration selects a different identity; it was left unchanged")

        # Different executable contents must retain one cryptographic identity.
        requirements = []
        for name in ("true", "false"):
            binary = directory / name
            shutil.copyfile("/usr/bin/" + name, binary)
            binary.chmod(0o700)
            run("/usr/bin/codesign", "--force", "--sign", fingerprint,
                "--keychain", str(KEYCHAIN), "--timestamp=none",
                "--identifier", "local.boringnotch.signingcheck", str(binary))
            run("/usr/bin/codesign", "--verify", "--strict", str(binary))
            requirements.append(signature(binary))
        if requirements[0][0] != requirements[1][0] or requirements[0][1] == requirements[1][1]:
            raise RuntimeError("Signing did not produce a stable identity across different builds")
        if fingerprint.lower() not in requirements[0][0].lower():
            raise RuntimeError("The signing requirement does not pin the dedicated certificate")
        for name in ("true", "false"):
            run("/usr/bin/codesign", "--verify", "--strict", "-R=" + requirements[0][0], str(directory / name))

        if CONFIG.exists():
            # Preserve unrelated machine-specific settings on subsequent runs.
            contents = CONFIG.read_text()
            style = r"^BORING_NOTCH_CODE_SIGN_STYLE\s*=.*$"
            if re.search(style, contents, re.MULTILINE):
                contents = re.sub(style, "BORING_NOTCH_CODE_SIGN_STYLE = Manual", contents, flags=re.MULTILINE)
            else:
                contents = contents.rstrip() + "\nBORING_NOTCH_CODE_SIGN_STYLE = Manual\n"
        else:
            contents = (
                "// This machine's persistent identity; do not commit or replace on rebuild.\n"
                "BORING_NOTCH_CODE_SIGN_IDENTITY = " + fingerprint + "\n"
                "BORING_NOTCH_CODE_SIGN_STYLE = Manual\n"
            )
        staged = CONFIG.with_suffix(".xcconfig.tmp")
        staged.write_text(contents)
        staged.replace(CONFIG)
        print("Verified: distinct builds have the same certificate-bound identity.")
        print("Configured " + str(CONFIG))
        print("Public certificate SHA-1: " + fingerprint)


if __name__ == "__main__":
    try:
        with CONFIG.with_suffix(".lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            main()
    except BlockingIOError:
        raise SystemExit("Another local signing setup is already running") from None
    except (RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from None
