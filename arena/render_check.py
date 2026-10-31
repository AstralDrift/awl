#!/usr/bin/env python3
"""How much of each request is past reasoning, rendered through a model's real chat template.

  arena/render_check.py TEMPLATE.jinja [--steps 40] [--reasoning 3000] [--result 1200] [--call 160]

TEMPLATE is a chat_template (Jinja), e.g. Qwen3's:
  curl -sL https://huggingface.co/Qwen/Qwen3-8B/resolve/main/tokenizer_config.json |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["chat_template"])' >/tmp/qwen3.jinja
Needs jinja2 (python3 -m pip install jinja2); it is a one-off tool, not part of t0.

Builds the history awl sends before step N: one user task, then N assistant tool-call turns, each
with a tool result, and renders it three ways: reasoning_content on every turn (awl's default,
AWL_KEEP_REASONING=on), on the newest K turns only (AWL_KEEP_REASONING=K), and none (0). Prints the
rendered size per request in characters (the reasoning text is identical in every variant, so the
character ratio is the token ratio) and the share of the prompt that is past reasoning.
"""
import sys

try:
    import jinja2
except ImportError:
    sys.exit("render_check: needs jinja2 (python3 -m pip install jinja2)")


def arg(name, default):
    a = sys.argv
    return type(default)(a[a.index(name) + 1]) if name in a else default


def history(n, reasoning, result, call, keep):
    """Messages as awl sends them before step n (0-based): keep = None (all), 0 (none) or newest K."""
    msgs = [{"role": "user", "content": "Fix the failing tests in this repository and make the build pass."}]
    for i in range(n):
        m = {"role": "assistant", "content": "",
             "tool_calls": [{"id": f"call_{i}", "type": "function",
                             "function": {"name": "bash", "arguments": '{"command":"' + ("x" * (call - 20)) + '"}'}}]}
        if keep is None or (keep and i >= n - keep):
            m["reasoning_content"] = f"step {i}: " + ("thinking " * (reasoning // 9))
        msgs.append(m)
        msgs.append({"role": "tool", "tool_call_id": f"call_{i}", "content": f"result {i}: " + ("output line\n" * (result // 12))})
    return msgs


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    env = jinja2.Environment(trim_blocks=True, lstrip_blocks=True)
    tmpl = env.from_string(open(sys.argv[1]).read())
    steps, reasoning, result, call = arg("--steps", 40), arg("--reasoning", 3000), arg("--result", 1200), arg("--call", 160)
    tools = [{"type": "function", "function": {"name": "bash", "parameters": {"type": "object", "properties": {"command": {"type": "string"}}}}}]

    def size(n, keep):
        return len(tmpl.render(messages=history(n, reasoning, result, call, keep), tools=tools, add_generation_prompt=True, enable_thinking=True))

    # Does the template keep reasoning on turns before the newest? Render 3 turns with reasoning only on turn 0.
    probe = history(3, reasoning, result, call, None)
    for m in probe[3:]:
        m.pop("reasoning_content", None)
    kept_old = "step 0: thinking" in tmpl.render(messages=probe, tools=tools, add_generation_prompt=True, enable_thinking=True)
    print(f"template keeps reasoning_content of earlier tool-call turns in the prompt: {'yes' if kept_old else 'no'}")
    print(f"synthetic run: {reasoning} chars of reasoning, a {call}-char call and a {result}-char result per step\n")
    print(f"{'before step':>11} | {'keep all (default)':>18} | {'newest 2':>9} | {'newest 1':>9} | {'none':>9} | past reasoning, keep all")
    for n in [1, 5, 10, 20, 30, steps]:
        if n > steps:
            break
        a, k2, k1, z = size(n, None), size(n, 2), size(n, 1), size(n, 0)
        print(f"{n:>11} | {a:>18,} | {k2:>9,} | {k1:>9,} | {z:>9,} | {(a - z) / a:5.0%}")
    total_all = sum(size(n, None) for n in range(1, steps + 1))
    total_k1 = sum(size(n, 1) for n in range(1, steps + 1))
    total_none = sum(size(n, 0) for n in range(1, steps + 1))
    print(f"\nprompt chars over {steps} steps: keep all {total_all:,}; newest 1 {total_k1:,} ({total_k1 / total_all:.0%}); none {total_none:,} ({total_none / total_all:.0%})")


if __name__ == "__main__":
    main()
