#!/usr/bin/env python3
"""
Explicit live evaluation script for small-model behavior on large-file editing.

Phase 7 of docs/LARGE_FILE_EDITING.md:
"Use explicitly requested live evaluation only for qualitative small-model behavior."

NOTE: Normal tests in `make test` are strictly model-free and do not require
live inference, network access, or credentials. This script is intended to be
run manually when qualitative evaluation of on-device Apple AFM or remote
OpenAI-compatible models is specifically desired.

Usage:
  python3 Scripts/eval-large-file.py --backend apple --pcc disable
  python3 Scripts/eval-large-file.py --backend openai --live
"""

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(
        description="Qualitative live evaluation for small-model large-file editing."
    )
    parser.add_argument(
        "--backend",
        choices=["apple", "openai"],
        default="apple",
        help="Inference backend to evaluate (default: apple)",
    )
    parser.add_argument(
        "--pcc",
        choices=["auto", "disable", "require"],
        default="disable",
        help="PCC policy for Apple backend (default: disable for 8K on-device)",
    )
    parser.add_argument(
        "--orchestration",
        choices=["auto", "always", "never"],
        default="auto",
        help="Orchestration mode (default: auto)",
    )
    parser.add_argument(
        "--max-rounds",
        type=int,
        default=8,
        help="Maximum rounds for the evaluation turn (default: 8)",
    )
    parser.add_argument(
        "--live",
        action="store_true",
        help="Explicitly confirm live model evaluation",
    )
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent

    # Enforce explicit request confirmation
    if not args.live and os.environ.get("TURBO_LIVE_EVAL") != "1":
        print(
            "NOTICE: Live evaluation requires explicit confirmation (--live or TURBO_LIVE_EVAL=1)."
        )
        print(
            "This ensures normal builds and test suites never access credentials or invoke models."
        )
        print(f"To run live evaluation against {args.backend}:")
        print(
            f"  python3 Scripts/eval-large-file.py --backend {args.backend} --pcc {args.pcc} --live"
        )
        sys.exit(0)

    # Check prerequisites
    if args.backend == "openai" and "OPENAI_API_KEY" not in os.environ:
        print("ERROR: OPENAI_API_KEY environment variable is required for openai backend evaluation.")
        sys.exit(1)

    print(f"=== Starting Qualitative Large-File Evaluation ({args.backend}) ===")
    print(f"Repository Root: {repo_root}")
    print(f"Backend: {args.backend} (PCC: {args.pcc})")
    print(f"Orchestration Mode: {args.orchestration}")

    # Build the TurboAgent CLI binary
    print("\n1. Building TurboAgent executable...")
    build_cmd = ["swift", "build", "-c", "release", "--product", "TurboAgent"]
    build_res = subprocess.run(build_cmd, cwd=repo_root)
    if build_res.returncode != 0:
        print("ERROR: Failed to build TurboAgent CLI.")
        sys.exit(build_res.returncode)

    executable = repo_root / ".build" / "release" / "TurboAgent"
    if not executable.exists():
        print(f"ERROR: Executable not found at {executable}")
        sys.exit(1)

    # Prepare temporary workspace with fixture
    with tempfile.TemporaryDirectory(prefix="turbo-eval-") as temp_dir:
        temp_path = Path(temp_dir)
        fixture_src = (
            repo_root
            / "Tests"
            / "TurboAgent"
            / "Fixtures"
            / "LargeFileEditing"
            / "LargeEditorFixture.c"
        )
        if not fixture_src.exists():
            print(f"ERROR: Fixture not found at {fixture_src}")
            sys.exit(1)

        target_file = temp_path / "Editor.c"
        target_file.write_text(fixture_src.read_text(encoding="utf-8"), encoding="utf-8")
        orig_bytes = target_file.stat().st_size
        print(f"\n2. Copied fixture to temporary workspace: {target_file} ({orig_bytes} bytes)")

        # Prepare evaluation prompt
        eval_prompt = (
            "Inspect Editor.c using range reads, repair cancel_prompt to clear "
            "the current draft upon cancellation, and verify the file."
        )

        agent_cmd = [
            str(executable),
            "--backend",
            args.backend,
            "--pcc",
            args.pcc,
            "--orchestration",
            args.orchestration,
            "--max-rounds",
            str(args.max_rounds),
            "--yolo",
        ]

        print(f"\n3. Running evaluation with prompt: \"{eval_prompt}\"")
        try:
            eval_res = subprocess.run(
                agent_cmd,
                input=eval_prompt + "\n",
                text=True,
                capture_output=True,
                cwd=temp_path,
                timeout=180,
            )
            stdout = eval_res.stdout
            stderr = eval_res.stderr

            print("\n4. Evaluation Results:")
            print("--------------------------------------------------")
            print(f"Exit code: {eval_res.returncode}")

            # Check if file changed and is valid UTF-8
            new_content = target_file.read_text(encoding="utf-8")
            file_changed = new_content != fixture_src.read_text(encoding="utf-8")
            has_cancel = "cancel_prompt" in new_content

            print(f"File modified: {file_changed}")
            print(f"Structure intact: {has_cancel}")

            # Extract metrics from stdout
            has_cmp = "cmp " in stdout or "Compacted" in stdout
            has_range = "lines=" in stdout or "start_line" in stdout
            print(f"Range reads observed: {has_range}")
            print(f"Compaction observed: {has_cmp}")

            print("--------------------------------------------------")
            if eval_res.returncode == 0 and has_cancel:
                print("Evaluation Status: PASSED")
            else:
                print("Evaluation Status: FAILED or INCOMPLETE")
                if stderr:
                    print("Stderr output:\n", stderr[:500])

        except subprocess.TimeoutExpired:
            print("ERROR: Evaluation timed out after 180 seconds.")
            sys.exit(1)


if __name__ == "__main__":
    main()
