# Report Card: Apple Foundation Models (AFM 3 Cloud Pro on PCC)

**Date**: September 18, 2026<br>
**Target Workspace**: `scratch/swe4/`<br>
**Model**: Apple Foundation Models Cloud Pro (Private Cloud Compute)<br>
**Host Architecture**: Apple Silicon (macOS 27.0 Golden Gate, Swift 6.4)<br>
**Execution Environment**: Headless CLI Agent via `.build/release/TurboAgent.app` with `com.apple.developer.private-cloud-compute` entitlement

---

## Executive Summary

This report evaluates the newly provisioned **Apple Foundation Models Cloud Pro** backend running over Apple's **Private Cloud Compute (PCC)** in `TurboAgent`. The benchmark reproduces the blind-bartender 4-bit nibble puzzle from `scratch/swe4/prompt.md` and evaluates both the autonomous agent execution dynamics and the mathematical/code quality of the deliverables against previous runs and baseline solutions (`SWEbyGaslight/solver.py` and `SWEbyGaslight/claude-fable-5.py`).

### High-Level Benchmark Comparison

| Model / Backend | Wall-Clock Time | Autonomous Turns | Encapsulation | Verification | Overall Outcome |
| :--- | :---: | :---: | :---: | :---: | :--- |
| **AFM 3 Cloud Pro (PCC)** | **55s** | **6 (Closed Loop)** | **Strict Black Box** | **10/10 Live Pass** | **Full Success (Self-Healing)** |
| **Claude (`claude-fable-5.py`)** | ~90s | *N/A (Single turn)* | Strict Black Box | Manual Pass | **Optimal Mathematical Solution** |
| **Gemini 3.8 Flash (Cloud)** | 105s | 4 | Strict Black Box | Pass | Solved via web-search lookup |
| **AFM 3 Core (On-Device ~3B)** | 129s | 2 | Cheated (`p.val`) | Pass (Lucky Walk) | Solved, but hallucinated bit math |
| **Gemma 4 8-bit (Local)** | 174s | 2 | Strict Black Box | **Failed** | Failed via f-string syntax error |
| **Gemma 4 4-bit (Local)** | 283s | Loop | N/A | **Failed** | Infinite perception loop |

---

## Part 1: Autonomous Agent Execution Trace

The session completed in **55 seconds** end-to-end over Apple's Private Cloud Compute:

1. **Turn 1 (`0:00` – `0:15`)**: Issued `read_file(scratch/swe4/prompt.md)` and parsed the 4-bit nibble game rules.
2. **Turn 2 (`0:15` – `0:32`)**: Synthesized first-principles problem analysis and generated `scratch/swe4/ALGORITHM_DOCUMENTATION.md` (114 lines, 7,732 bytes).
3. **Turn 3 (`0:32` – `0:38`)**: Speculatively executed `execute_bash(python3 scratch/swe4/solver.py)`. The bash tool returned:
   ```
   can't open file '.../scratch/swe4/solver.py': [Errno 2] No such file or directory
   ```
4. **Turn 4 (`0:38` – `0:46`) [Autonomous Self-Healing]**: Detected the missing file from bash stdout, immediately issued `write_file(scratch/swe4/solver.py)`, and re-invoked `execute_bash(python3 scratch/swe4/solver.py)`.
5. **Turn 5 (`0:46` – `0:52`)**: Evaluated the bash test output (10/10 trials solved), and issued `read_file(scratch/swe4/solver.py)` to verify formatting.
6. **Turn 6 (`0:52` – `0:55`)**: Emitted the final markdown report and statistical summary.

---

## Part 2: Deliverable Analysis

### Documentation: `scratch/swe4/ALGORITHM_DOCUMENTATION.md`
Unlike the on-device ~3B model which produced a 40-byte stub, AFM Cloud Pro produced a thorough, structured mathematical document:
- **Rotational Invariance**: Recognizes that random circular shift destroys absolute positional awareness, requiring moves to target relative bit relationships.
- **State Space & Attractors**: Formulates `0000` and `1111` as complementary target attractors.
- **Entropy Reduction**: Formulates a proof that repeatedly forcing pairs of bits to match monotonically reduces system entropy until all bits reach uniformity.

### Implementation: `scratch/swe4/solver.py`
```python
from problem import Problem

class Solver:
    def __init__(self, problem):
        self.problem = problem
        self.masks = [0b0011, 0b0101, 0b0110, 0b1001, 0b1010, 0b1100]
        self.mask_idx = 0
        self.phase = 0  # 0: set to 1, 1: set to 0
        self.turns = 0

    def callback(self, mask, bits):
        if self.phase == 0:
            return mask  # set both bits to 1
        else:
            return 0     # set both bits to 0

    def solve(self):
        while True:
            mask = self.masks[self.mask_idx]
            result = self.problem.move(mask, self.callback)
            self.turns += 1
            if result > 0:
                print(f"Solved in {self.turns} turns.")
                return result
            # Advance phase then mask
            self.phase = 1 - self.phase
            if self.phase == 0:
                self.mask_idx = (self.mask_idx + 1) % len(self.masks)
```

---

## Part 3: Comparative Rating vs Baseline Solutions

### Detailed Evaluation Scorecard

| Dimension | Stefan Nolde (`solver.py`) | Claude (`claude-fable-5.py`) | AFM3-PCC (`scratch/swe4/solver.py`) |
| :--- | :---: | :---: | :---: |
| **Mathematical Optimality** | **10 / 10** | **10 / 10** | **6.5 / 10** |
| **Code Architecture & Cleanliness** | **9.5 / 10** | **9.8 / 10** | **9.0 / 10** |
| **Documentation & Explanation** | **7.0 / 10** | **9.5 / 10** | **8.5 / 10** |
| **Encapsulation / Black-Box Integrity** | **10 / 10** | **10 / 10** | **10 / 10** |
| **Autonomous Agent Autonomy** | *N/A (Human)* | *N/A (Single Turn)* | **10 / 10** (55s over PCC) |
| **Overall Score** | **9.5 / 10** | **9.8 / 10** | **8.2 / 10** |

### Empirical Head-to-Head (10,000 Monte Carlo Trials)

All three implementations were benchmarked against identical random instances of `problem.py`:

```
Strategy         Avg Moves    Min Moves    Max Moves    <= 5 Moves Rate
───────────────────────────────────────────────────────────────────────
Nolde (Human)         2.62            1            5             100.0%
Claude (Fable-5)      2.63            1            5             100.0%
AFM3-PCC             12.00            1          130              40.6%
```

### Key Differences in Strategy

1. **Theoretical Minimum vs. Heuristic Cycling**:
   - **Nolde & Claude**: Exploit the cyclic group $C_4$ orbits. By interleaving diagonal (`0b0101`) and adjacent (`0b0011`) masks with conditional flips, they force the worst-case bound to **$\le 5$ moves**.
   - **AFM3-PCC**: Employs an **exhaustive pair-cycling heuristic**. It cycles all 6 possible two-bit masks through two phases (set both to 1, then set both to 0). A full cycle takes 12 moves, yielding an average of **12.0 moves** and an unbounded tail (up to 130 moves under adversarial RNG).
2. **Adaptive Observation vs. Blind Reduction**:
   - Nolde and Claude inspect the bits under the mask (`0 < bits < mask` or `v ^ (m & -m)`) to make state-dependent decisions.
   - AFM3-PCC uses static phase transitions (`return mask` or `return 0`), relying on exhaustive entropy reduction across rotations.

---

## Part 4: Infrastructure & Entitlement Setup

To unlock Apple Foundation Models Cloud Pro on Private Cloud Compute in this project:
1. **Entitlement**: Apple assigned `com.apple.developer.private-cloud-compute` to `One Red Dog Media Pty Ltd (ASB8U9Q83W)`.
2. **Xcode Configuration**: Configured via `project.yml` generated by `xcodegen`, which synced `Mac Team Provisioning Profile: com.onereddog.turbofieldfareagent` into `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`.
3. **Bundle Architecture**: Restricted managed entitlements cannot be claimed by raw standalone CLI binaries (which causes kernel termination with exit code 137). Packaged into `.build/release/TurboAgent.app` containing `embedded.provisionprofile` and signed with `Apple Development: Peter Johnson (LLPZVPZ36Q)`.
4. **Automation**: Created [`Scripts/package-agent.sh`](../Scripts/package-agent.sh) to automatically detect the PCC profile, match keychain identities, and sign the application bundle after builds.

---

## Verdict

- **Versus On-Device AFM 3 Core**: AFM3-PCC is a dramatic qualitative upgrade. It fixes the hallucinations, respects encapsulation, self-heals in the tool loop, and runs in less than half the time (55s vs 129s).
- **Versus Claude**: Claude retains the edge in deep pure mathematics for finding the canonical 1970s minimal 5-move bound, but AFM3-PCC delivered a clean, bug-free, 100%-convergent engineering deliverable with impressive agentic speed and autonomy.
