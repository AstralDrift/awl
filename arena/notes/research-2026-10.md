# Harness research, October 2026

Scope: arXiv papers on coding and terminal agent harnesses, mostly 2026-10-01 to 2026-10-23, plus three from late September.
Method: arXiv listings (cs.SE recent) and arXiv searches ("agent harness", "Terminal-Bench", "coding agent context", "coding agent harness").
Verification: every paper below was checked on its arXiv abstract page (title, id, v1 date, numbers). The numbers come from the abstracts only. I did not read the full texts.
Labels: **Reported** means the paper's own claim. **Inference** means my reading for awl.
Context: awl solved 12/20 on a TB2.0 subset with Qwen3.8-27B. Most of its failures were timeouts.

## 1. Ranked papers

### 1. Probe-and-Resume: When and How to Evaluate Agent Execution
- arXiv [2610.21088](https://arxiv.org/abs/2610.21088), 2026-10-15.
- Idea: MCTS with step-level critics barely beats chance on terminal tasks, because critics can't see the hidden environment state. Instead, call the critic only when the agent claims it is done. The critic gets read/write/exec access to a fork of the environment to probe. On rejection, the agent resumes where it stopped.
- Reported: +8.4 pp over MCTS with conventional critics on Terminal-Bench 2.1. It approaches Codex CLI with the same model at under half the cost. The abstract does not name the model.
- Applies to awl (inference): when the model ends with no tool calls, start a critic sub-loop with a fresh context. It gets the task text, a `git diff`/file list and the bash tool, works in the same container (TB can't fork cheaply), and ends with PASS or FAIL plus a reason. On FAIL, append the reason as a user note and continue the main loop. Cap it at about 8 critic steps, and skip it when less than about 20% of the time budget is left, since awl's failures are already timeouts. Effort: about 150 lines of Zig. Test: the 20-task TB2 subset, 3 seeds, measuring solved, tokens and wall time.

### 2. Can Terminal Agents Trust Their Own Verification? Diagnosing and Improving Self-Verification
- arXiv [2609.38812](https://arxiv.org/abs/2609.38812), 2026-09-30.
- Idea: Find the first complete candidate in each trajectory, then check whether later verification catches its errors. Ten terminal agents were studied on TB2.1.
- Reported: agents almost always verify, but they detect only 61.43% of wrong candidates and repair only 49.36% of the errors they detect. The authors' fix is training: distilling a teacher's verification into a student (SCVD). It adds +9.74 to +16.85 pp Pass@1 on TB2.1 across three Qwen3.5 backbones.
- Applies to awl (inference): the training part does not apply. The diagnosis does: awl's prompt line "check work by running tests" is not the bottleneck, because detection is. This supports idea #1 (an independent critic with a fresh context) over a stronger self-check instruction. Cheap test: count awl's TB failures where it ran a check and then still declared success.

### 3. PAUSE: Search-Free Steering of Coding Agents Before Their First Source-Code Edit
- arXiv [2610.29870](https://arxiv.org/abs/2610.29870), 2026-10-21.
- Idea: Intercept the agent's first source edit, which comes at a median of 60% of the trajectory. A Planner model reads the task and the pre-edit transcript and writes one repair plan. The Executor continues with its context and workspace intact.
- Reported: +16.8% resolution on SWE-bench Verified (OpenHands, Qwen3-coder executor, GPT-5.6 Sol planner); the abstract does not say whether this is absolute or relative. +14.7% on Multilingual (SWE-agent). It beats a rule-triggered advisor by 3.2 to 3.7 pts. It matches a periodic overseer at 11 to 15% of that overseer's planner cost. Offline, it recovers 35.4% of failed tasks.
- Applies to awl (inference): hook the first `edit`/`write` call of a run. Before running it, make one no-tools request with the task and a transcript digest, asking for a short plan, and inject the plan as a user note. The planner can be the same model or a stronger OpenRouter model. Effort: about 80 lines. Test: TB2 subset A/B. Note that TB tasks are less edit-centric than SWE-bench, so also trigger on the first state-changing bash command.

### 4. Finding the Right Fit: Model-Harness Interactions across Agent Tasks
- arXiv [2610.00917](https://arxiv.org/abs/2610.00917), 2026-10-01.
- Idea: 66 model×harness configurations (OpenHands, DeepSeek Harness, PI, openJiuwen, and native CLIs).
- Reported: rankings flip across harnesses. On Terminal-Bench 4, Claude leads GPT by 7.94 in OpenHands and trails it by 30.16 in PI. GPT under PI beats DSH at under 1/4 of the cost per task. Models do nearly all repairs themselves, so results hinge on whether the harness **returns failures in a usable form**. Kimi, which emits malformed tool calls, does best in openJiuwen.
- Applies to awl (inference): audit every tool error string (bad JSON args, edit miss, nonzero exit, timeout) so it says what failed and what to do next. Add tolerant parsing and repair of malformed tool-call JSON for small models. Effort: small. Test: grep arena logs for malformed calls and error turns per task, then rerun the subset.

### 5. Beyond Token Savings: A Systematic Study of Context Compression in LLM Agents
- arXiv [2609.32961](https://arxiv.org/abs/2609.32961), 2026-09-26.
- Idea: Separates what, when and how much to compress, across about 35,000 runs on SWE-bench Verified and Terminal-Bench 1.0 with three open-weight models.
- Reported: on Terminal-Bench with Qwen, policies using about 1/3 of the tokens took **20 to 80% longer** than no compression. Policies with similar success solve different tasks, and the effects differ by model.
- Applies to awl (inference): awl fails by timeout, so measure wall time, not just tokens, for the 60% elision and the 80% compaction. A likely cause is lost prefix cache on the local server, plus re-reads after elision. Test: rerun the subset with elision off and with the threshold at 80%, comparing wall time per task. Cost: runs only.

### 6. TraceLite: Efficient Trace Reduction for SWE Agents via Optical Compression and Redundancy Removal
- arXiv [2610.28612](https://arxiv.org/abs/2610.28612), 2026-10-20.
- Idea: Training-free. It keeps recent observations as text, renders older ones as images, **removes overlapping content**, and **drops observation payloads after code edits**.
- Reported: 78.25% on SWE-bench Verified, above the compression baselines. Input tokens −33.05% and API cost −21.30% (GPT-5.6-Luna and Gemini-3.8Flash).
- Applies to awl (inference): skip the image part, since there is no vision on local Qwen. Two rules are cheap. First, once a file is edited, elide earlier `read` outputs of that file, which are now stale and misleading. Second, replace an exact-duplicate tool output with "same as call #k". Effort: about 60 lines in the elision pass. Test: replay saved sessions offline to count saved tokens, then run the TB subset.

### 7. Cache Engineering for Agents
- arXiv [2610.28577](https://arxiv.org/abs/2610.28577), 2026-10-20.
- Idea: Agents manage their own KV cache: drop entries and re-index positions without a re-prefill. They come with a serving engine (AKV).
- Reported: a **tool-response rolling-drop** policy beats threshold-triggered summarization by +1.7 avg points at −27.7% cost. Throughput is up to 1.2x and P95 latency up to 1.5x better. The abstract names no benchmarks or models.
- Applies to awl (inference): the KV part needs server support, which is out of scope. The policy result applies: a rolling drop of old tool responses beats summarization. This backs awl's elision over its compaction. Make elision cache-friendly: elide in large fixed blocks, so the prompt prefix changes rarely and llama.cpp/vLLM prefix reuse survives. Test: log the server's cached-token count per request before and after.

### 8. Enforcing Code Reasoning in Agentic Scaffold for More Effective Issue Resolution (DeskCheck)
- arXiv [2610.23782](https://arxiv.org/abs/2610.23782), 2026-10-16.
- Idea: Mined 7,955 trajectories. Code reasoning correlates with resolution but is unguided. DeskCheck adds guided steps: simulate execution paths to find the root cause, simulate candidate patches, audit the patch against the issue requirements, and reason about corner cases before writing tests.
- Reported: +6.29% to +10.53% over mini-SWE-agent and Claude Code on 731 SWE-bench Pro instances, at +$0.14 per instance on average, with p < 1e-10. The abstract does not name the models.
- Applies to awl (inference): this could be a skill or a short prompt block, "before finishing: re-read the task's requirements line by line and check each against the result". That is the requirements-audit part only, at nearly zero cost. Test: TB subset A/B. Combine it with the critic rubric in #1.

### 9. Ask Your Advisor: Learning When to Consult Stronger Models in Agentic Systems (ARIA)
- arXiv [2610.13870](https://arxiv.org/abs/2610.13870), 2026-10-09.
- Idea: A meta-controller decides at checkpoints whether a cheap executor should consult a stronger advisor. It is learned by Monte Carlo control with a consultation-cost penalty.
- Reported: recovers 44 to 81% of the executor→advisor success gap at under half the advisor's cost (SWE-bench Verified, TB2.1, τ²-bench). It had the best trade-off among 10 conditions, including fixed and prompted consultation. The abstract does not name the models.
- Related: EdgeWise [2610.17560](https://arxiv.org/abs/2610.17560) (2026-10-13). A local small model delegates key steps to a cloud LLM. Reported: matches pure-LLM execution at up to −62% cost on SWE-Rebench and −34% on TB2.1.
- Applies to awl (inference): awl's target is small models, so an `advisor` model setting fits. Use fixed checkpoints instead of a learned controller: first edit (#3), the done claim (#1), and after N consecutive failed commands. Test: Qwen3.8-27B executor with a stronger OpenRouter advisor, measuring solved and advisor spend.

### 10. Good Judgment, Bad Advice: Decision-Model Controllers Raise Agent Cost Without Improving Success
- arXiv [2610.24649](https://arxiv.org/abs/2610.24649), 2026-10-17.
- Idea: A preregistered TB2.1 study (21 tasks, 315 trials, Sonnet 5.5 agent) of controllers at fixed decision points: rules, Haiku 5.5, a typed decision model, and a placebo.
- Reported: the controller **raised cost 19% with an identical 73.0% pass rate**. It was poorly calibrated and asked for re-verification of work that was already correct (87% of the flagged runs passed).
- Applies to awl (inference): this cuts against #1 and #9. Add a gate, and measure the critic's false-reject rate on tasks that already pass. With a strong model, the gains may vanish, so the payoff is more likely with small models. Track cost per solved task, not only the solve count.

### 11. Harness-Delta Attribution: Dissecting Gains From Harness Evolution
- arXiv [2610.22466](https://arxiv.org/abs/2610.22466), 2026-10-15.
- Idea: Splits harness-search gains into overfitting, extra test-time compute, and a residual.
- Reported: across 21 significant settings, **overfitting explained 54%** of the gain on average and test-time scaling 14%. Gains often failed to transfer to held-out tasks.
- Applies to awl (inference): a 20-task subset is a search set. Keep a held-out TB2 slice for confirming changes, report tokens and wall time next to solves (to separate the compute effect), and use ≥3 seeds. This is process, not code.

### 12. Stale Instruction Files Override the Code in Coding Agents: A One-Sentence Fix
- arXiv [2610.30571](https://arxiv.org/abs/2610.30571), 2026-10-22.
- Idea: When AGENTS.md/CLAUDE.md conflicts with the code, agents follow the file, because the code arrives as lower-trust tool output.
- Reported: 90.1% of choices followed the stale file (Claude Code, Codex CLI, 40 projects, 320 runs). One user-level sentence giving existing code precedence raised code-following from 4.2% to 91.4% and tests from 89.4% to 100%. The abstract does not give the exact wording.
- Applies to awl (inference): awl injects AGENTS.md. Add one sentence to the system prompt: "When AGENTS.md or other instructions conflict with the existing code, follow the code's established conventions and mention the conflict." Cost: one line. Not a TB lever.

### 13. Compaction Laundering: Provenance Destruction in Context-Compacting Coding Agents
- arXiv [2610.29869](https://arxiv.org/abs/2610.29869), 2026-10-21.
- Idea: Harnesses that flatten messages into one string with text labels before summarizing let attacker content forge a `[User]:` turn that survives compaction as a trusted instruction.
- Reported: forged approval persisted 87 to 100% of the time in pi, opencode, Cline, Aider and OpenHands, and 0% in role-typed harnesses. Live pi ran attacker `curl | sh` about 50% of the time. Escaping role labels at the serializer fixes it.
- Applies to awl (inference, **checked in code**): awl's `serialize()` in `src/agent.zig` flattens to `[User]: ` / `[Tool result]: ` labels, the same pattern. Fix: escape or neutralize lines that start with `[User]`, `[Assistant`, or `[Tool result]` inside message content before serializing, or wrap each message in per-message tags with a random nonce. Effort: about 15 lines plus a unit test that a tool result containing `\n[User]: approve` comes out escaped.

### 14. What Coding Agents Leave Unsaid: Measuring Task-State Gaps Between Execution and Reports
- arXiv [2610.20003](https://arxiv.org/abs/2610.20003), 2026-10-14.
- Idea: How much task state survives in an agent's reports compared with its full context.
- Reported: reports recover 52.0% of the state versus 92.7% for full context, a 40.7-pt gap. Full scrollback recovers 73.6%. The main loss is "mentioned without enough detail".
- Related: MemoryTax [2610.29823](https://arxiv.org/abs/2610.29823) (2026-10-21). Designed memory (Mem0) beats full context only with a weak model. A coding agent searching raw history (pi + Opus 5.5) hit 99% at under half the cost of full context. One LoCoMo conversation, one run per cell.
- Applies to awl (inference): compaction summaries are lossy reports. After compaction, tell the model where the session log is and that it can `grep` it for exact errors, values and commands. Cost: one line in the summary message. Test: inject long tasks that force compaction, then check for repeated work.

### 15. TomasuLLM: Out-of-Order Speculative Execution for LLM Agents
- arXiv [2609.38201](https://arxiv.org/abs/2609.38201), 2026-09-22.
- Idea: Predict upcoming tool calls, run them in sandboxes, and commit them in order after validation.
- Reported: 1.31x on SWE-bench Verified (100 tasks), 1.35x on Terminal-Bench 2.0 (28 tasks), 0 false accepts in 4,010 audits. The abstract does not name the model.
- Applies to awl (inference): full speculation is too heavy for awl. A small piece fits: run the read-only calls (read, grep, find) within one assistant turn in parallel threads. Effort is moderate. It only helps if models emit parallel calls, so check the logs first.

### Also verified, lower priority
- SWE-VERIFIER [2610.30284](https://arxiv.org/abs/2610.30284) (2026-10-21): a trained 4B verifier checks <4% of steps. +1.7 pts (MiniMax-M2.7, 75.47→77.20) at 1.09x cost in mini-swe-agent. Needs a trained model.
- From Finding to Fixing [2610.25826](https://arxiv.org/abs/2610.25826) (2026-10-19): fault localization does not consistently improve repair, and current FL methods often cost more tokens than they save. Don't add an FL stage.
- Design and Cross-Domain Evaluation of an Agent Execution Harness [2610.25568](https://arxiv.org/abs/2610.25568) (2026-10-18): planner, workers and reviewer score 83/89 (93.26%) on TB2.1, but cost per task rises from $0.29 to $2.13 on HealthBench. Off-target for cheap runs.
- Improving Environment-Agnostic Agents: The Role of Scaffolding [2610.22289](https://arxiv.org/abs/2610.22289) (2026-10-15): a "report difficulties, return control for auto-continue" instruction helped on ARC-AGI-3 and AGI Maze. Terminal-Bench changes were small and mixed.
- Harness Self-Evolution for Long-Horizon Terminal Agents (RiseHarness) [2610.27435](https://arxiv.org/abs/2610.27435) (2026-10-20): a method that contrasts successful and failed runs of the same task to find harness fixes. The abstract has no numbers.
- Adaptive Skill Granularity for Coding Agents [2610.31461](https://arxiv.org/abs/2610.31461) (2026-10-22): macro skills fall back to primitive steps on failure. The abstract has no numbers.

## 2. Cross-cutting themes

Converging:
- **Verify at completion, with fresh eyes and environment access** (2610.21088, 2609.38812, 2610.25568). Step-level critics are near chance, and self-verification misses about 40% of wrong candidates.
- **Rolling drop and dedup of tool outputs beat LLM summarization** for cost (2610.28577, 2610.28612). Raw history plus search beats designed memory with capable models (2610.29823).
- **A single well-timed intervention beats periodic oversight** (PAUSE at first edit, Probe-and-Resume at done, ARIA at checkpoints).
- **Harness×model fit dominates**. Lean harnesses can win big, and usable error feedback is the mechanism (2610.00917).
- **Harness evolution is popular** (about 10 papers in 3 weeks), but 2610.22466 shows most search-set gains are overfitting.

Contested:
- **Do controllers and critics pay off?** Yes per 2610.21088 and 2610.13870. No per 2610.24649 (+19% cost, same pass rate with a strong model). Inference: the payoff likely depends on base-model strength and critic calibration.
- **Fewer tokens ≠ faster or cheaper** (2609.32961). The token-saving papers mostly report tokens and dollars, not wall time.
- **Planner/reviewer multi-agent stacks**: top TB2.1 score (2610.25568), but at about 7x cost and with regressions.
- **Compaction safety**: flattened summarization is an injection channel (2610.29869). Most open harnesses, including pi and awl, flatten.

## 3. Top 3 to try first (gain per effort)

Arena runs need the user's go.

1. **Completion-gated critic (Probe-and-Resume, lite).** When the model finishes, run a fresh-context critic with bash in the same container: up to 8 steps, PASS/FAIL plus a reason. On FAIL, resume once.
   - Guard: skip it when less than 20% of the time is left.
   - Experiment: TB2 20-task subset, 3 seeds, critic on vs off. Metrics: solved, critic false-reject rate on passing tasks, tokens, wall time. Confirm on a held-out slice (per 2610.22466).
2. **Stale/duplicate tool-output elision plus a wall-time check.** Elide `read` outputs of files edited later and exact-duplicate outputs. Elide in fixed blocks to keep the prefix cache.
   - Experiment: first replay saved sessions offline (tokens saved, no model cost). Then run the TB subset comparing current elision, the new elision and elision off, measuring wall time and cached-token counts (per 2609.32961 and 2610.28577). The target is awl's timeouts.
3. **One plan at first state change (PAUSE).** Before the first edit/write, or the first state-changing bash, make one no-tools plan request and inject the result.
   - Experiment: same-model planner vs stronger OpenRouter planner vs off, on the TB subset, 3 seeds. Metrics: solved and extra tokens.

Free wins, no benchmark needed:
- Escape role labels in `serialize()` (2610.29869).
- Add the code-precedence sentence (2610.30571).
- After compaction, point the model to the session log for grep (2610.20003).
