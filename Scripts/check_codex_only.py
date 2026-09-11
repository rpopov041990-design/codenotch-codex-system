"""Static regression checks, not a substitute for build/runtime verification."""
from pathlib import Path
import plistlib
import re

root = Path(__file__).resolve().parents[1]
app = (root / "Sources/App/AppDelegate.swift").read_text()
updater = (root / "Sources/App/Updater.swift").read_text()
relay = (root / "Sources/Sessions/OllamaActivityRelay.swift").read_text()
settings = (root / "Sources/Settings/SettingsView.swift").read_text()
project = (root / "project.yml").read_text()
info = plistlib.loads((root / "Sources/Info.plist").read_bytes())

assert "private let codexProfiles: [CodexProfile] = [.default()]" in app
assert "providers: codexProfiles.map { CodexLocalProvider(profile: $0) }," in app
assert not re.search(r"(?:Claude|Cursor|Grok|Antigravity|Gemini|GLM|OpenCode|CommandCode|GitHubCopilot)\w*\(", app)
assert "ClaudeProfile.discover" not in app
assert "ClaudeTokenRefresher" not in app
assert "Preferences.migrateFromPreviousName()" not in app
assert "startingUpdater: false" in updater
assert "func start() { }" in updater
assert "controller.updater.checkForUpdates()" not in updater
assert "let enabled = false" in relay
assert "SettingsSection.allCases.filter { $0 != .ollama }" in settings
assert "OllamaSettingsRow(preferences:" not in settings
assert "PRODUCT_BUNDLE_IDENTIFIER: local.codex.codenotch-only" in project
assert info["SUEnableAutomaticChecks"] is False
assert info["SUAutomaticallyUpdate"] is False
print("PASS: 16 static Codex-only isolation checks (runtime not tested)")
