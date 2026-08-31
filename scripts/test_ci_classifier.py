#!/usr/bin/env python3
"""Positive and negative fixtures for the conservative CI path classifier."""

from __future__ import annotations

import unittest
from pathlib import Path

from ci_classifier import GATES, classify_paths


class ClassifierTests(unittest.TestCase):
    def assert_gates(self, paths: list[str], selected: set[str], absent: set[str] | None = None):
        result = classify_paths(paths)
        self.assertEqual({gate for gate in GATES if result[gate]}, selected)
        for gate in absent or set():
            self.assertFalse(result[gate], f"{gate} unexpectedly selected for {paths}")

    def test_docs_only_selects_pages_without_expensive_validation(self):
        self.assert_gates(
            ["docs/TROUBLESHOOTING.md"],
            {"pages"},
            {"renderer", "package", "installer", "container"},
        )

    def test_agents_only_uses_fast_layer(self):
        self.assert_gates(["AGENTS.md"], set())

    def test_packaged_platform_guide_selects_package_and_pages(self):
        self.assert_gates(["docs/windows/README.md"], {"package", "pages"})

    def test_renderer_runtime_selects_platform_package_and_image_gates(self):
        self.assert_gates(
            ["platforms/nas-docker/app/TautWeekly.ps1"],
            {"powershell", "renderer", "package", "container"},
            {"container_arm64"},
        )

    def test_scheduler_does_not_select_full_renderer(self):
        self.assert_gates(
            ["platforms/nas-docker/app/Scheduler.ps1"],
            {"powershell", "package", "container"},
            {"renderer"},
        )

    def test_manager_selects_all_consumers_and_multiarch(self):
        self.assert_gates(
            ["manager/internal/manager/server.go"],
            {"manager", "package", "installer", "container", "container_arm64"},
        )

    def test_installer_does_not_select_renderer_or_container(self):
        self.assert_gates(
            ["installer/cmd/tautweekly-setup/main.go"],
            {"package", "installer"},
            {"renderer", "container"},
        )

    def test_compose_only_does_not_select_image_build(self):
        self.assert_gates(
            ["platforms/nas-docker/compose.yaml"],
            {"package", "compose"},
            {"renderer", "container"},
        )

    def test_dockerfile_selects_multiarch_image(self):
        self.assert_gates(
            ["platforms/nas-docker/Dockerfile"],
            {"package", "container", "container_arm64"},
        )

    def test_ci_workflow_change_fails_closed_to_every_gate(self):
        self.assert_gates([".github/workflows/ci.yml"], set(GATES))

    def test_release_history_validator_stays_in_the_fast_layer(self):
        self.assert_gates(["scripts/validate-release-history.ps1"], set())

    def test_unknown_executable_input_fails_closed(self):
        self.assert_gates(["tools/new-build-helper.py"], set(GATES) - {"pages"})

    def test_manual_scopes_are_explicit(self):
        self.assertFalse(any(classify_paths(["manager/go.mod"], "fast").values()))
        self.assertTrue(all(classify_paths(["AGENTS.md"], "full").values()))


class WorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ci = Path(".github/workflows/ci.yml").read_text(encoding="utf-8")
        cls.container = Path(".github/workflows/container.yml").read_text(encoding="utf-8")
        cls.pages = Path(".github/workflows/pages.yml").read_text(encoding="utf-8")
        cls.release = Path(".github/workflows/release.yml").read_text(encoding="utf-8")

    def test_ci_events_are_pr_main_and_manual_only(self):
        on_block = self.ci.split("\npermissions:", 1)[0]
        self.assertRegex(on_block, r"(?m)^  pull_request:\s*$")
        self.assertRegex(on_block, r"(?m)^  push:\n    branches: \[main\]$")
        self.assertRegex(on_block, r"(?m)^  workflow_dispatch:\s*$")
        self.assertNotIn("tags:", on_block)
        self.assertNotIn("paths:", on_block)

    def test_required_aggregate_is_stable_and_fail_closed(self):
        required = self.ci.split("\n  required:", 1)[1].split(
            "\n  publish-edge-container:", 1
        )[0]
        self.assertIn("\n    name: required\n", required)
        self.assertIn("\n    if: always()\n", required)
        for dependency in (
            "provenance",
            "classify",
            "fast",
            "fast-windows-powershell",
            "powershell-runtime-unix",
            "powershell-runtime-windows",
            "renderer-unix",
            "renderer-windows",
            "manager",
            "package",
            "installer",
            "compose",
            "container-validation",
        ):
            self.assertIn(f"      - {dependency}\n", required)
        self.assertIn(
            "ci-provenance-pr-${{ github.event.pull_request.number }}"
            "-base-${{ github.event.pull_request.base.sha }}"
            "-head-${{ github.event.pull_request.head.sha }}",
            required,
        )
        self.assertIn("> ci-provenance.txt", required)
        self.assertIn("path: ci-provenance.txt", required)

    def test_expensive_renderer_runs_once_and_only_in_selected_gate(self):
        self.assertEqual(self.ci.count("test-newsletter-integration.ps1"), 1)
        self.assertRegex(
            self.ci,
            r"renderer-windows:[\s\S]+needs\.classify\.outputs\.renderer == 'true'"
            r"[\s\S]+test-newsletter-integration\.ps1",
        )
        self.assertNotIn("test-newsletter-integration.ps1", self.release)

    def test_publication_workflows_have_no_direct_push_or_pr_trigger(self):
        for workflow in (self.container, self.pages):
            on_block = workflow.split("\npermissions:", 1)[0]
            if "\njobs:" in on_block:
                on_block = on_block.split("\njobs:", 1)[0]
            self.assertNotRegex(on_block, r"(?m)^  push:")
            self.assertNotRegex(on_block, r"(?m)^  pull_request:")
            self.assertRegex(on_block, r"(?m)^  workflow_call:")
        self.assertNotIn("\n    permissions:", self.container)

    def test_main_publications_run_after_successful_aggregate_with_skipped_gates(self):
        publish = self.ci.split("\n  publish-edge-container:", 1)[1].split(
            "\n  deploy-pages:", 1
        )[0]
        pages = self.ci.split("\n  deploy-pages:", 1)[1]
        for block, selected in ((publish, "container"), (pages, "pages")):
            self.assertIn("if: always() &&", block)
            self.assertIn("needs.required.result == 'success'", block)
            self.assertIn(
                f"needs.classify.outputs.{selected} == 'true'",
                block,
            )

    def test_release_is_tag_only_and_requires_green_exact_commit(self):
        on_block = self.release.split("\npermissions:", 1)[0]
        self.assertIn("      - 'v*.*.*'", on_block)
        self.assertIn("Release history, version, and CI provenance", self.release)
        self.assertIn("check_name: 'required'", self.release)
        self.assertIn(
            "./scripts/validate-release-history.ps1 -Version $version", self.release
        )
        self.assertNotIn(
            "(Get-Content -LiteralPath $file.FullName -Raw).Trim() -ne $version",
            self.release,
        )
        self.assertIn("./scripts/validate-release-history.ps1", self.ci)
        self.assertEqual(self.release.count("./scripts/build-releases.ps1"), 1)
        self.assertNotIn("./scripts/validate-repository.ps1", self.release)

    def test_generated_mac_runtime_profile_is_checked_in_the_package_only(self):
        self.assertNotIn(
            "test -x platforms/mac-docker/app/bin/runtime-profile.sh", self.ci
        )
        self.assertIn(
            "tar -tvzf dist/TautWeekly-mac-docker.tar.gz "
            "TautWeekly-mac-docker/app/bin/runtime-profile.sh | grep -q '^-rwx'",
            self.ci,
        )


if __name__ == "__main__":
    unittest.main()
