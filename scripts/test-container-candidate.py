#!/usr/bin/env python3
"""Synthetic OCI indexes exercise publication refusal without any registry writes."""
import copy
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path
import unittest

MODULE = Path(__file__).with_name("container-candidate.py")
SPEC = importlib.util.spec_from_file_location("container_candidate", MODULE)
candidate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(candidate)


class Fixture:
    def __init__(self, architectures=("amd64", "arm64"), predicates=None, wrong_subject=False, modern=False):
        self.content = {}
        self.index = {"schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json", "manifests": []}
        for arch in architectures:
            config = self.add("blobs", {"architecture": arch, "os": "linux", "config": {"Labels": {"org.opencontainers.image.version": "0.27.3"}}})
            image = self.add("manifests", {"schemaVersion": 2, "config": config, "layers": [{"size": 17}]})
            image["platform"] = {"os": "linux", "architecture": arch}
            self.index["manifests"].append(image)
            layers = []
            for predicate in predicates if predicates is not None else [candidate.SBOM, sorted(candidate.PROVENANCE)[0]]:
                target = "0" * 64 if wrong_subject else image["digest"].split(":")[1]
                layers.append(self.add("blobs", {"predicateType": predicate, "subject": [{"digest": {"sha256": target}}], "predicate": {}}))
            attestation = {"schemaVersion": 2, "layers": layers}
            if modern:
                attestation["subject"] = copy.deepcopy(image)
            descriptor = self.add("manifests", attestation)
            descriptor["platform"] = {"os": "unknown", "architecture": "unknown"}
            if not modern:
                descriptor["annotations"] = {"vnd.docker.reference.type": "attestation-manifest", "vnd.docker.reference.digest": image["digest"]}
            self.index["manifests"].append(descriptor)

    def add(self, kind, value):
        raw = json.dumps(value, sort_keys=True).encode()
        reference = candidate.digest(raw)
        self.content[kind, reference] = raw
        return {"digest": reference, "size": len(raw)}

    def validate(self, architectures=("amd64", "arm64"), version="0.27.3"):
        reference = self.add("manifests", self.index)["digest"]
        return candidate.validate_candidate(lambda kind, digest: self.content[kind, digest], reference, list(architectures), version)


class CandidateTests(unittest.TestCase):
    def test_exact_architectures_version_and_both_attestations_pass(self):
        result = Fixture().validate()
        self.assertEqual(set(result["platforms"]), {"amd64", "arm64"})
        self.assertEqual(result["version"], "0.27.3")
        self.assertEqual(result["platforms"]["arm64"]["compressedLayerBytes"], 17)

    def test_modern_oci_subject_attestations_pass(self):
        Fixture(modern=True).validate()

    def test_single_architecture_pr_candidate_passes(self):
        Fixture(("amd64",)).validate(("amd64",))

    def test_missing_sbom_or_provenance_fails(self):
        for predicates in ([candidate.SBOM], [sorted(candidate.PROVENANCE)[0]], []):
            with self.subTest(predicates=predicates), self.assertRaisesRegex(ValueError, "both SBOM and provenance"):
                Fixture(predicates=predicates).validate()

    def test_attestation_cannot_refer_to_a_different_image(self):
        with self.assertRaisesRegex(ValueError, "does not identify"):
            Fixture(wrong_subject=True).validate()

    def test_same_platform_twice_fails(self):
        fixture = Fixture()
        fixture.index["manifests"].append(copy.deepcopy(fixture.index["manifests"][0]))
        with self.assertRaisesRegex(ValueError, "Duplicate runnable"):
            fixture.validate()

    def test_missing_architecture_fails(self):
        with self.assertRaisesRegex(ValueError, "differs from expected"):
            Fixture(("amd64",)).validate()

    def test_extra_platform_fails(self):
        with self.assertRaisesRegex(ValueError, "Unexpected platform"):
            Fixture(("amd64", "arm64", "386")).validate()

    def test_version_must_be_final_version(self):
        with self.assertRaisesRegex(ValueError, "does not match"):
            Fixture().validate(version="ci")

    def test_registry_cannot_change_manifest_bytes_under_digest(self):
        fixture = Fixture()
        reference = fixture.index["manifests"][0]["digest"]
        fixture.content["manifests", reference] += b" "
        with self.assertRaisesRegex(ValueError, "does not match descriptor"):
            fixture.validate()

    def test_registry_descriptor_size_is_verified(self):
        fixture = Fixture()
        fixture.index["manifests"][0]["size"] += 1
        with self.assertRaisesRegex(ValueError, "does not match descriptor"):
            fixture.validate()

    def test_registry_address_is_fixed_to_job_local_service(self):
        for registry, repository in (("https://example.com", "image"), ("http://localhost:5000", "../image")):
            with self.subTest(registry=registry), self.assertRaises(ValueError):
                candidate.registry_fetcher(registry, repository)


class RuntimeContractTests(unittest.TestCase):
    def test_go_builders_compile_each_target_on_the_native_build_platform(self):
        root = Path(__file__).resolve().parents[1]
        for relative in ("platforms/nas-docker/Dockerfile", "platforms/mac-docker/Dockerfile.registry"):
            text = (root / relative).read_text()
            self.assertTrue(text.startswith("FROM --platform=$BUILDPLATFORM golang:1.26.6-bookworm AS manager-build"), relative)
            builder = text.split("FROM tailscale/", 1)[0]
            self.assertIn("ARG TARGETARCH", builder)
            self.assertIn('CGO_ENABLED=0 GOOS=linux GOARCH="${TARGETARCH:-amd64}"', builder)


    def test_mac_runtime_uses_canonical_powershell_download_and_dependency_bytes(self):
        root = Path(__file__).resolve().parents[1]
        canonical = (root / "platforms/nas-docker/Dockerfile").read_text()
        def runtime_dependencies(text):
            return text.split("RUN apt-get update", 1)[1].split("RUN groupadd", 1)[0]
        for name in ("Dockerfile", "Dockerfile.registry"):
            text = (root / "platforms/mac-docker" / name).read_text()
            self.assertIn("FROM debian:bookworm-slim", text)
            self.assertIn("ARG POWERSHELL_VERSION=7.4.16", text)
            self.assertNotIn("dotnet/sdk", text)
            self.assertEqual(runtime_dependencies(text), runtime_dependencies(canonical))
        fallback = (root / "platforms/mac-docker/Dockerfile").read_text()
        self.assertIn("FROM scratch AS manager-binaries", fallback)
        final = fallback.split("FROM debian:bookworm-slim", 1)[1]
        self.assertIn("COPY --from=manager-binaries --chmod=0755 /tautweekly-manager-linux-${TARGETARCH}", final)
        self.assertNotIn("COPY manager/", final)
        self.assertNotIn("/tmp/tautweekly-manager", final)



class WorkflowPlanTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(__file__).resolve().parents[1]
        cls.workflow = (cls.root / ".github/workflows/container.yml").read_text()
        match = re.search(r"      - name: Resolve final candidate version and platforms.*?        run: \|\n(.*?)(?=      - name:)", cls.workflow, re.S)
        if not match:
            raise AssertionError("Candidate plan command is missing.")
        cls.plan = textwrap.dedent(match.group(1))
        cls.bash = shutil.which("bash") or "C:/Program Files/Git/bin/bash.exe"

    def run_plan(self, mode, version, smoke, arm64, tag=""):
        with tempfile.TemporaryDirectory(prefix="tautweekly-plan-") as temporary:
            output = Path(temporary) / "output"
            environment = dict(os.environ, PUBLISH_MODE=mode, BUILD_VERSION=version, SMOKE_TEST=smoke, TEST_ARM64=arm64, RELEASE_TAG=tag, GITHUB_OUTPUT=str(output).replace("\\", "/"))
            process = subprocess.run([self.bash, "-e", "-s"], input=self.plan, text=True, capture_output=True, env=environment)
            return process, output.read_text() if output.exists() else ""

    def test_release_refuses_omitted_architecture_or_boot_tests(self):
        for smoke, arm in (("false", "true"), ("true", "false"), ("false", "false")):
            with self.subTest(smoke=smoke, arm=arm):
                process, output = self.run_plan("release", "0.27.3", smoke, arm, "v0.27.3")
                self.assertNotEqual(process.returncode, 0)
                self.assertEqual(output, "")

    def test_release_builds_final_version_for_both_platforms(self):
        process, output = self.run_plan("release", "0.27.3", "true", "true", "v0.27.3")
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertIn("version=0.27.3\n", output)
        self.assertIn("platforms=linux/amd64,linux/arm64\n", output)

    def test_edge_preserves_provenance_only_main_policy(self):
        process, output = self.run_plan("edge", "edge", "false", "false")
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertIn("platforms=linux/amd64,linux/arm64\n", output)

    def test_pr_can_select_only_amd64_without_publication(self):
        process, output = self.run_plan("none", "ci", "true", "false")
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertIn("platforms=linux/amd64\n", output)
        self.assertNotIn("linux/arm64", output)

    def test_release_tag_version_disagreement_fails(self):
        process, _ = self.run_plan("release", "0.27.3", "true", "true", "v0.27.2")
        self.assertNotEqual(process.returncode, 0)

    def test_publication_never_rebuilds_or_drops_attestations(self):
        self.assertEqual(self.workflow.count("uses: docker/build-push-action@"), 1)
        publish = self.workflow.split("      - name: Publish the verified index without rebuilding", 1)[1]
        self.assertNotIn("docker/build-push-action", publish)
        self.assertNotIn("docker push", publish)
        self.assertIn("--all --preserve-digests", publish)
        self.assertIn("--verify-index", publish)
        self.assertIn("if: inputs.publish_mode == 'edge' || inputs.publish_mode == 'release'", publish)
        self.assertLess(self.workflow.index("Boot-test the exact arm64 digest"), self.workflow.index("Publish the verified index without rebuilding"))
        self.assertIn("CANDIDATE_IMAGE: ${{ steps.verified.outputs.amd64_ref }}", self.workflow)
        self.assertIn("CANDIDATE_IMAGE: ${{ steps.verified.outputs.arm64_ref }}", self.workflow)

    def test_promoted_index_requires_byte_identical_digest(self):
        with tempfile.TemporaryDirectory(prefix="tautweekly-index-") as temporary:
            index = Path(temporary) / "index.json"
            raw = b'{"schemaVersion":2,"manifests":[]}'
            index.write_bytes(raw)
            command = [sys.executable, "-B", str(MODULE), "--digest", candidate.digest(raw), "--verify-index", str(index)]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            index.write_bytes(raw + b"\n")
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)

if __name__ == "__main__":
    unittest.main()
