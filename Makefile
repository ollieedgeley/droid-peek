.DEFAULT_GOAL := help

.PHONY: help check lint lint-qml lint-rust fix fix-qml fix-rust \
	check-qml-format coverage supply-chain architecture \
	check-release-version generate-build-info

help:
	@printf '%s\n' \
		'Droid Peek developer targets:' \
		'  check                  Run the complete developer gate' \
		'  lint                   Lint QML and Rust' \
		'  lint-qml               Lint shipped QML' \
		'  lint-rust              Check Rust formatting and Clippy' \
		'  fix                     Apply available QML and Rust lint fixes' \
		'  fix-qml                Apply qmllint fixes, then lint shipped QML' \
		'  fix-rust               Apply Rustfmt and Clippy fixes, then lint Rust' \
		'  check-qml-format       Check shipped QML against qmlformat' \
		'  coverage               Enforce focused Rust coverage floors' \
		'  supply-chain           Check Rust dependencies and advisories' \
		'  architecture           Check architecture ownership rules' \
		'  check-release-version  Check release metadata consistency' \
		'  generate-build-info    Regenerate versioned QML and Lua build info'

check:
	@scripts/dev/check.sh

lint: lint-qml lint-rust

lint-qml:
	@scripts/dev/lint-qml.sh

lint-rust:
	@scripts/dev/lint-rust.sh

fix: fix-qml fix-rust

fix-qml:
	@scripts/dev/lint-qml.sh --fix

fix-rust:
	@scripts/dev/lint-rust.sh --fix

check-qml-format:
	@scripts/dev/check-qml-format.sh

coverage:
	@scripts/dev/check-coverage.sh

supply-chain:
	@scripts/dev/check-supply-chain.sh

architecture:
	@scripts/dev/check-architecture.sh

check-release-version:
	@scripts/dev/check-release-version

generate-build-info:
	@scripts/dev/generate-build-info
