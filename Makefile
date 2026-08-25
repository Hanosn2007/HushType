APP_NAME = HushType
BUILD_DIR = .build/release
# Callers may direct packaging to a staging path so a development build never
# overwrites an app bundle that is currently running. The traditional local
# output remains the default for explicit release packaging.
BUNDLE_DIR ?= $(APP_NAME).app

# OpenCC paths (Homebrew on Apple Silicon)
OPENCC_BIN = /opt/homebrew/bin/opencc
OPENCC_LIB_DIR = /opt/homebrew/lib
OPENCC_DATA_DIR = /opt/homebrew/share/opencc
MARISA_LIB_DIR = /opt/homebrew/opt/marisa/lib

.PHONY: build run bundle bundle-opencc install uninstall dmg clean l10n-verify l10n-verify-dest

# Supported interface-localization locale dirs copied into the app bundle.
L10N_LOCALES = en.lproj zh-Hans.lproj zh-Hant-TW.lproj
# Known pre-release legacy dir that must never survive in a built bundle.
L10N_LEGACY_LOCALES = zh-Hant.lproj
L10N_SOURCE_MANIFEST = .build/l10n_source_manifest.json

# Gate: validate the source .lproj tables (structure, lint, key parity,
# recursive format signatures, frozen-catalog cross-check) and emit the
# semantic manifest. Fatal on any failure; stale output cannot mask it.
l10n-verify:
	bash scripts/check_localizations.sh --source-manifest "$(L10N_SOURCE_MANIFEST)"

# Gate: validate the built bundle's .lproj dirs and require their semantic
# manifest to equal the source manifest (run before and after codesign).
l10n-verify-dest:
	bash scripts/check_localizations.sh --dest "$(BUNDLE_DIR)/Contents/Resources" --source-manifest "$(L10N_SOURCE_MANIFEST)"

build:
	swift build -c release --disable-sandbox
	bash scripts/build_mlx_metallib.sh release
	@echo "Build complete: $(BUILD_DIR)/$(APP_NAME)"

run: build
	$(BUILD_DIR)/$(APP_NAME)

bundle: build l10n-verify
	@mkdir -p "$(BUNDLE_DIR)/Contents/MacOS"
	@mkdir -p "$(BUNDLE_DIR)/Contents/Resources"
	@cp "$(BUILD_DIR)/$(APP_NAME)" "$(BUNDLE_DIR)/Contents/MacOS/"
	@cp "$(BUILD_DIR)/mlx.metallib" "$(BUNDLE_DIR)/Contents/MacOS/" 2>/dev/null || true
	@cp Resources/Info.plist "$(BUNDLE_DIR)/Contents/"
	@cp Resources/HushType.icns "$(BUNDLE_DIR)/Contents/Resources/" 2>/dev/null || true
	@cp scripts/ios_server.py "$(BUNDLE_DIR)/Contents/Resources/" 2>/dev/null || true
	@# Interface localization: remove ONLY the exact supported + known legacy
	@# destination locale dirs, then copy the fresh source .lproj dirs. This is
	@# what makes the negative stale-output test honest — a previous bundle
	@# with deleted tables/keys or a stale zh-Hant.lproj can never satisfy the
	@# post-copy destination manifest check (l10n-verify-dest).
	@for d in $(L10N_LOCALES) $(L10N_LEGACY_LOCALES); do rm -rf "$(BUNDLE_DIR)/Contents/Resources/$$d"; done
	@for d in $(L10N_LOCALES); do cp -R "Sources/HushType/Resources/$$d" "$(BUNDLE_DIR)/Contents/Resources/"; done
	@$(MAKE) l10n-verify-dest
	@# Strip debug symbols + scrub developer-path leakage from the binary
	@# before signing. Two distinct fixes:
	@#   (a) `strip -S` removes debug symbols.
	@#   (b) `__FILE__` macro expansions inside Cmlx (MLX's C++ shim) bake
	@#       absolute paths from the build worktree into the data segment —
	@#       these survive `strip` because they're runtime-accessible string
	@#       literals, not debug info. The python step does a length-preserving
	@#       binary patch: replaces the user-home prefix with `/redacted` + null
	@#       padding so `strings` returns nothing identifying the developer.
	@# Both happen BEFORE codesign because modifying the binary invalidates
	@# the signature.
	@strip -S "$(BUNDLE_DIR)/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true
	@python3 -c "import sys, pathlib; \
binary = pathlib.Path('$(BUNDLE_DIR)/Contents/MacOS/$(APP_NAME)'); \
prefix = b'$(PWD)'; \
data = binary.read_bytes(); \
count = data.count(prefix); \
replacement = b'/redacted' + b'\x00' * (len(prefix) - 9); \
binary.write_bytes(data.replace(prefix, replacement)) if count else None; \
print(f'  Scrubbed {count} dev-path occurrence(s) from binary')"
	@# Local-only MVP keeps Qwen's Simplified Chinese output and does not
	@# expose Traditional conversion, so OpenCC is intentionally not bundled.
	@# The bundle-opencc target remains available for a future Hant build.
	@echo "OpenCC skipped (local Simplified-Chinese MVP)"
	@# Sign the entire bundle with an explicit stable identifier so macOS TCC
	@# tracks accessibility permission by identifier (constant across builds)
	@# instead of cdhash (which changes every build). Without this, every
	@# `make install` revokes the user's previously-granted permission.
	@# --deep is required because Mach-O binaries inside a bundle can't be
	@# signed independently — codesign always treats them as part of the
	@# enclosing bundle.
	@codesign --force --deep --sign - --identifier "com.felix.hushtype" "$(BUNDLE_DIR)"
	@# Verify the final signature on the built bundle. Fatal on any nested
	@# invalid signature (e.g. a dylib modified after its inner sign).
	@codesign --verify --deep --strict "$(BUNDLE_DIR)"
	@# Re-validate the localization manifest on the signed bundle: the copy
	@# happened before signing, but this proves the shipped signature covers a
	@# bundle whose resources equal the source manifest.
	@$(MAKE) l10n-verify-dest
	@echo "Bundle created: $(BUNDLE_DIR) (signed as com.felix.hushtype, debug symbols stripped)"

bundle-opencc:
	@echo "Bundling OpenCC..."
	@mkdir -p "$(BUNDLE_DIR)/Contents/MacOS/opencc_data"
	@# Copy opencc binary
	@cp "$(OPENCC_BIN)" "$(BUNDLE_DIR)/Contents/MacOS/opencc"
	@# Copy dylibs
	@cp "$(OPENCC_LIB_DIR)/libopencc.1.2.dylib" "$(BUNDLE_DIR)/Contents/MacOS/"
	@cp "$(MARISA_LIB_DIR)/libmarisa.0.dylib" "$(BUNDLE_DIR)/Contents/MacOS/"
	@# Copy data files (dictionaries + configs)
	@cp "$(OPENCC_DATA_DIR)"/*.json "$(BUNDLE_DIR)/Contents/MacOS/opencc_data/"
	@cp "$(OPENCC_DATA_DIR)"/*.ocd2 "$(BUNDLE_DIR)/Contents/MacOS/opencc_data/"
	@# Rewrite dylib paths to use @executable_path
	@install_name_tool -change "@rpath/libopencc.1.2.dylib" "@executable_path/libopencc.1.2.dylib" "$(BUNDLE_DIR)/Contents/MacOS/opencc"
	@install_name_tool -change "/opt/homebrew/opt/marisa/lib/libmarisa.0.dylib" "@executable_path/libmarisa.0.dylib" "$(BUNDLE_DIR)/Contents/MacOS/opencc"
	@install_name_tool -change "/opt/homebrew/opt/marisa/lib/libmarisa.0.dylib" "@executable_path/libmarisa.0.dylib" "$(BUNDLE_DIR)/Contents/MacOS/libopencc.1.2.dylib"
	@# Fix libopencc's own id
	@install_name_tool -id "@executable_path/libopencc.1.2.dylib" "$(BUNDLE_DIR)/Contents/MacOS/libopencc.1.2.dylib"
	@install_name_tool -id "@executable_path/libmarisa.0.dylib" "$(BUNDLE_DIR)/Contents/MacOS/libmarisa.0.dylib"
	@# Re-sign after install_name_tool — modifying load commands invalidates the
	@# original Homebrew adhoc signature, and macOS Sequoia kills processes with
	@# invalid signatures (SIGKILL, no error). Without this step, the bundled
	@# opencc fails silently and ChineseConverter falls back to returning the
	@# input unchanged. Both `make install` and `make dmg` need this.
	@codesign --force --sign - "$(BUNDLE_DIR)/Contents/MacOS/libmarisa.0.dylib"
	@codesign --force --sign - "$(BUNDLE_DIR)/Contents/MacOS/libopencc.1.2.dylib"
	@codesign --force --sign - "$(BUNDLE_DIR)/Contents/MacOS/opencc"
	@echo "OpenCC bundled (binary + dylibs + data files, re-signed)"

install: bundle
	@killall $(APP_NAME) 2>/dev/null || true
	@rm -rf /Applications/$(BUNDLE_DIR)
	@cp -R "$(BUNDLE_DIR)" /Applications/
	@echo "Installed to /Applications/$(BUNDLE_DIR)"
	@echo "You can now launch HushType from Spotlight (Cmd+Space → HushType)"

uninstall:
	@killall $(APP_NAME) 2>/dev/null || true
	@rm -rf /Applications/$(BUNDLE_DIR)
	@echo "Uninstalled from /Applications"

dmg: bundle
	@# OpenCC binaries are already signed in bundle-opencc; just sign the outer bundle.
	@echo "Signing app bundle..."
	@codesign --force --deep --sign - "$(BUNDLE_DIR)"
	@rm -f $(APP_NAME).dmg
	@mkdir -p dmg_staging
	@cp -R "$(BUNDLE_DIR)" dmg_staging/
	@ln -s /Applications dmg_staging/Applications
	@hdiutil create -volname "$(APP_NAME)" -srcfolder dmg_staging -ov -format UDZO "$(APP_NAME).dmg"
	@rm -rf dmg_staging
	@echo "Created $(APP_NAME).dmg"

clean:
	swift package clean
	rm -rf $(BUNDLE_DIR) $(APP_NAME).dmg
