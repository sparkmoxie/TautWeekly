#!/usr/bin/env python3
"""Validate an exact local OCI candidate before boot tests and publication."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import urllib.request
from pathlib import Path

DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
SBOM = "https://spdx.dev/Document"
PROVENANCE = {"https://slsa.dev/provenance/v0.2", "https://slsa.dev/provenance/v1"}


def digest(raw: bytes) -> str:
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def checked_json(fetch, kind: str, reference: str, size: int | None = None):
    if not DIGEST.fullmatch(reference):
        raise ValueError(f"Invalid content digest: {reference}")
    raw = fetch(kind, reference)
    if digest(raw) != reference or (size is not None and len(raw) != size):
        raise ValueError(f"Registry content does not match descriptor: {reference}")
    return json.loads(raw)


def descriptor_json(fetch, kind, descriptor):
    return checked_json(fetch, kind, descriptor["digest"], descriptor["size"])


def validate_candidate(fetch, reference: str, architectures: list[str], version: str):
    index = checked_json(fetch, "manifests", reference)
    if index.get("schemaVersion") != 2 or not isinstance(index.get("manifests"), list):
        raise ValueError("Candidate must be an OCI/Docker image index.")
    expected = set(architectures)
    if not expected or not expected <= {"amd64", "arm64"} or len(architectures) != len(expected):
        raise ValueError("Expected architectures must be a unique nonempty amd64/arm64 list.")
    platforms = {}
    attestations = []
    for descriptor in index["manifests"]:
        platform = descriptor.get("platform", {})
        annotations = descriptor.get("annotations", {})
        if platform.get("os") == "linux" and platform.get("architecture") in expected:
            arch = platform["architecture"]
            if arch in platforms:
                raise ValueError(f"Duplicate runnable architecture: {arch}")
            manifest = descriptor_json(fetch, "manifests", descriptor)
            config = descriptor_json(fetch, "blobs", manifest["config"])
            if config.get("architecture") != arch or config.get("os") != "linux":
                raise ValueError(f"Image configuration does not match platform: {arch}")
            actual_version = config.get("config", {}).get("Labels", {}).get("org.opencontainers.image.version")
            if actual_version != version:
                raise ValueError(f"Image version {actual_version!r} does not match {version!r}: {arch}")
            platforms[arch] = {
                "digest": descriptor["digest"],
                "configDigest": manifest["config"]["digest"],
                "compressedLayerBytes": sum(layer["size"] for layer in manifest["layers"]),
                "predicates": set(),
            }
        elif (platform.get("os") == "unknown" and platform.get("architecture") == "unknown") or annotations.get("vnd.docker.reference.type") == "attestation-manifest":
            attestations.append(descriptor)
        else:
            raise ValueError(f"Unexpected platform descriptor: {platform}")
    if set(platforms) != expected:
        raise ValueError(f"Runnable architecture set {sorted(platforms)} differs from expected {sorted(expected)}")
    by_digest = {value["digest"]: value for value in platforms.values()}
    for descriptor in attestations:
        manifest = descriptor_json(fetch, "manifests", descriptor)
        target = descriptor.get("annotations", {}).get("vnd.docker.reference.digest")
        subject = manifest.get("subject", {}).get("digest")
        if target and subject and target != subject:
            raise ValueError("Attestation descriptor and manifest subjects disagree.")
        target = target or subject
        if target not in by_digest:
            raise ValueError("Attestation is not attached to a runnable candidate manifest.")
        for layer in manifest.get("layers", []):
            statement = descriptor_json(fetch, "blobs", layer)
            subjects = statement.get("subject", [])
            if not any(item.get("digest", {}).get("sha256") == target.split(":", 1)[1] for item in subjects):
                raise ValueError("Attestation statement does not identify its runnable manifest.")
            by_digest[target]["predicates"].add(statement.get("predicateType"))
    for arch, platform in platforms.items():
        if SBOM not in platform["predicates"] or not (PROVENANCE & platform["predicates"]):
            raise ValueError(f"Candidate {arch} requires both SBOM and provenance attestations.")
        platform["predicates"] = sorted(platform["predicates"])
    return {"schemaVersion": 1, "digest": reference, "version": version, "platforms": platforms}


def registry_fetcher(registry: str, repository: str):
    # Candidate inspection is deliberately limited to the job-local registry.
    if registry != "http://localhost:5000" or not re.fullmatch(r"[a-z0-9][a-z0-9/-]*", repository):
        raise ValueError("Candidate inspection requires the fixed job-local registry and a safe repository path.")

    def fetch(kind, reference):
        request = urllib.request.Request(f"{registry}/v2/{repository}/{kind}/{reference}", headers={
            "Accept": ", ".join(("application/vnd.oci.image.index.v1+json", "application/vnd.docker.distribution.manifest.list.v2+json", "application/vnd.oci.image.manifest.v1+json", "application/vnd.docker.distribution.manifest.v2+json")),
        })
        with urllib.request.urlopen(request, timeout=30) as response:
            maximum = 96 * 1024 * 1024
            raw = response.read(maximum + 1)
        if len(raw) > maximum:
            raise ValueError("Registry metadata exceeded its bounded inspection size.")
        return raw
    return fetch


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--digest", required=True)
    parser.add_argument("--registry", default="http://localhost:5000")
    parser.add_argument("--repository", default="tautweekly/candidate")
    parser.add_argument("--architectures", default="amd64,arm64")
    parser.add_argument("--version")
    parser.add_argument("--output")
    parser.add_argument("--github-output")
    parser.add_argument("--verify-index", type=Path, help="Verify a promoted raw index has the original digest.")
    args = parser.parse_args()
    if args.verify_index:
        if not DIGEST.fullmatch(args.digest) or digest(args.verify_index.read_bytes()) != args.digest:
            raise ValueError("Promoted index digest differs from the validated candidate.")
        print("[PASS] Promoted index preserves the validated runnable and attestation descriptors.")
        return
    if not args.version or not args.output:
        parser.error("Candidate inspection requires --version and --output.")
    evidence = validate_candidate(registry_fetcher(args.registry, args.repository), args.digest, args.architectures.split(","), args.version)
    Path(args.output).write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as output:
            for arch, platform in evidence["platforms"].items():
                output.write(f"{arch}_ref=localhost:5000/{args.repository}@{platform['digest']}\n")
    for arch, platform in evidence["platforms"].items():
        print(f"[PASS] {arch}: {platform['digest']}; compressed layers {platform['compressedLayerBytes']} bytes; final version {args.version}; SBOM and provenance verified.")


if __name__ == "__main__":
    main()
