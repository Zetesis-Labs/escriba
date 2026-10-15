import os
import pathlib
import plistlib
import subprocess
import tempfile
import unittest
import zipfile


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "package-macos.sh"


class MacOSPackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.app = self.root / "source" / "Escriba.app"
        (self.app / "Contents" / "MacOS").mkdir(parents=True)
        (self.app / "Contents" / "Resources").mkdir()
        with (self.app / "Contents" / "Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleShortVersionString": "1.2.3"}, stream)
        (self.app / "Contents" / "MacOS" / "escriba-runtime").write_bytes(b"\xcf\xfa\xed\xfeBUN")
        (self.app / "Contents" / "MacOS" / "escriba-tauri").write_bytes(b"\xcf\xfa\xed\xfeAPP")
        (self.app / "Contents" / "MacOS" / "EscribaSystemHost").write_bytes(b"\xcf\xfa\xed\xfeHOST")
        (self.app / "Contents" / "Resources" / "addon.node").write_bytes(b"\xcf\xfa\xed\xfeNODE")
        self.out = self.root / "out"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls"
        for name in ("codesign", "security", "ditto", "xcrun", "spctl"):
            path = self.bin / name
            path.write_text("#!/usr/bin/env python3\n" + MOCK)
            path.chmod(0o755)

    def run_package(self, flag, credentials=False, notary_status="Accepted", failure=""):
        env = os.environ.copy()
        env.update(PATH=str(self.bin) + os.pathsep + env["PATH"], MOCK_CALLS=str(self.log), MOCK_NOTARY_STATUS=notary_status, MOCK_FAILURE=failure)
        if flag is None:
            env.pop("MACOS_NOTARIZE", None)
        else:
            env["MACOS_NOTARIZE"] = flag
        for key in ("APPLE_CERTIFICATE", "APPLE_CERTIFICATE_PASSWORD", "APPLE_SIGNING_IDENTITY", "APPLE_ID", "APPLE_APP_SPECIFIC_PASSWORD", "APPLE_TEAM_ID"):
            env.pop(key, None)
        if credentials:
            env.update(APPLE_CERTIFICATE="Y2VydA==", APPLE_CERTIFICATE_PASSWORD="password", APPLE_SIGNING_IDENTITY="Developer ID Application: Test (TEAM123)", APPLE_ID="dev@example.org", APPLE_APP_SPECIFIC_PASSWORD="password", APPLE_TEAM_ID="TEAM123")
        return subprocess.run(["bash", str(SCRIPT), str(self.app), "v1.2.3", str(self.out)], env=env, text=True, capture_output=True)

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_invalid_flag_fails_before_side_effects(self):
        result = self.run_package("yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MACOS_NOTARIZE", result.stderr)
        self.assertFalse(self.out.exists())
        self.assertEqual(self.calls(), [])

    def test_missing_credentials_fails_before_side_effects(self):
        result = self.run_package("true")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("APPLE_CERTIFICATE", result.stderr)
        self.assertFalse(self.out.exists())
        self.assertEqual(self.calls(), [])

    def test_ad_hoc_zip_contains_verified_app_and_readme_without_mutating_source(self):
        result = self.run_package("false")
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = self.out / "Escriba_1.2.3_macos_arm64_sin-notarizar.zip"
        self.assertTrue(archive.exists())
        with zipfile.ZipFile(archive) as package:
            self.assertIn("Escriba.app/Contents/MacOS/escriba-runtime", package.namelist())
            self.assertIn("LEEME.txt", package.namelist())
            readme = package.read("LEEME.txt").decode()
            self.assertIn("macOS 26", readme)
            self.assertIn("Apple Silicon (M1", readme)
            self.assertIn("Abrir igualmente", readme)
            self.assertIn("https://support.apple.com/es-es/102445", readme)
        self.assertTrue((self.out / "SHA256SUMS-macos-arm64").exists())
        self.assertEqual((self.app / "Contents" / "MacOS" / "escriba-runtime").read_bytes(), b"\xcf\xfa\xed\xfeBUN")
        self.assertFalse((self.app / "Contents" / "_CodeSignature").exists())
        self.assertIn("Paquete preparado", result.stdout)
        self.assertGreaterEqual(len([call for call in self.calls() if call.startswith("codesign --verify")]), 2)

    def test_signing_failure_publishes_nothing(self):
        result = self.run_package("false", failure="codesign")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.out.exists())
        self.assertEqual((self.app / "Contents" / "MacOS" / "escriba-runtime").read_bytes(), b"\xcf\xfa\xed\xfeBUN")

    def test_signature_verification_failure_publishes_nothing(self):
        result = self.run_package("false", failure="verify")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.out.exists())

    def test_rejected_notarization_publishes_nothing_and_cleans_keychain(self):
        result = self.run_package("true", credentials=True, notary_status="Invalid", failure="notary-nonzero")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid", result.stderr)
        self.assertIn("synthetic test", result.stderr)
        self.assertFalse(self.out.exists())
        self.assertTrue(any(call.startswith("security delete-keychain") for call in self.calls()))

    def test_staple_failure_publishes_nothing(self):
        result = self.run_package("true", credentials=True, failure="staple")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.out.exists())
        self.assertTrue(any(call.startswith("security delete-keychain") for call in self.calls()))

    def test_accepted_notarization_staples_before_final_zip_and_cleans_keychain(self):
        result = self.run_package("true", credentials=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        staple = next(i for i, call in enumerate(calls) if call.startswith("xcrun stapler staple"))
        self.assertTrue(any(i > staple and call.startswith("ditto -c") for i, call in enumerate(calls)))
        self.assertTrue(any(call.startswith("security delete-keychain") for call in calls))
        archive = self.out / "Escriba_1.2.3_macos_arm64.zip"
        self.assertTrue(archive.exists())
        with zipfile.ZipFile(archive) as package:
            readme = package.read("LEEME.txt").decode()
            self.assertIn("Aplicaciones", readme)
            self.assertNotIn("Abrir igualmente", readme)
        self.assertTrue(any("EscribaSystemHost" in call and "audio-entitlements.plist" in call for call in calls))


MOCK = '''import json, os, pathlib, shutil, sys, zipfile
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["MOCK_CALLS"], "a") as stream:
    stream.write(name + " " + " ".join(args) + "\\n")
if name == "security":
    if args[0] == "create-keychain": pathlib.Path(args[-1]).touch()
    if args[0] == "find-identity": print('1) ABC "Developer ID Application: Test (TEAM123)"')
elif name == "ditto":
    if args[0] == "-c":
        with zipfile.ZipFile(args[-1], "w") as package:
            for file in pathlib.Path(args[-2]).rglob("*"):
                if file.is_file():
                    relative = file.relative_to(args[-2])
                    if "--keepParent" in args: relative = pathlib.Path(args[-2]).name / relative
                    package.write(file, relative)
    elif args[0] == "-x":
        with zipfile.ZipFile(args[-2]) as package: package.extractall(args[-1])
    elif pathlib.Path(args[-2]).is_dir(): shutil.copytree(args[-2], args[-1], dirs_exist_ok=True)
    else: shutil.copy2(args[-2], args[-1])
elif name == "codesign" and "--force" in args:
    if os.environ["MOCK_FAILURE"] == "codesign": sys.exit(7)
    target = pathlib.Path(args[-1])
    if target.is_dir():
        (target / "Contents" / "_CodeSignature").mkdir(exist_ok=True)
        (target / "Contents" / "_CodeSignature" / "MockSignature").write_text("signed")
    else:
        with target.open("ab") as stream: stream.write(b"SIGNED")
elif name == "codesign" and "--verify" in args and os.environ["MOCK_FAILURE"] == "verify":
    sys.exit(8)
elif name == "xcrun" and args[:2] == ["notarytool", "submit"]:
    with zipfile.ZipFile(args[2]) as package:
        if "Escriba.app/Contents/Info.plist" not in package.namelist(): sys.exit(19)
    print(json.dumps({"id": "TEST-ID", "status": os.environ["MOCK_NOTARY_STATUS"]}))
    if os.environ["MOCK_FAILURE"] == "notary-nonzero": sys.exit(3)
elif name == "xcrun" and args[:2] == ["notarytool", "log"]:
    print("Notarization rejected: synthetic test")
elif name == "xcrun" and args[:2] == ["stapler", "staple"] and os.environ["MOCK_FAILURE"] == "staple":
    sys.exit(4)
'''


if __name__ == "__main__":
    unittest.main()
