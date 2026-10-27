"""Harbor adapter for awl: uploads the static binary into the task container and runs
`awl -p INSTRUCTION` there. awl needs no runtime, so install is one file copy.

Env (host side, read when the job starts):
  AWL_BIN      path to the awl binary (default: <repo>/zig-out/bin/awl)
  AWL_TB_URL   model endpoint as seen from the container, IPv4 literal
               (awl has no DNS), e.g. http://172.21.0.9:18080/run/awl
  AWL_TB_MODEL model id
"""
import os
import shlex
from pathlib import Path

from harbor.agents.installed.base import BaseInstalledAgent, with_prompt_template
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

REPO = Path(__file__).resolve().parents[2]


class Awl(BaseInstalledAgent):
    @staticmethod
    def name() -> str:
        return "awl"

    def get_version_command(self) -> str | None:
        return "/installed-agent/awl --version"

    def parse_version(self, stdout: str) -> str:
        return stdout.strip().removeprefix("awl ").strip()

    async def install(self, environment: BaseEnvironment) -> None:
        binary = os.environ.get("AWL_BIN") or str(REPO / "zig-out/bin/awl")
        await environment.upload_file(binary, "/installed-agent/awl")
        await self.exec_as_root(environment, "chmod 755 /installed-agent/awl")

    def populate_context_post_run(self, context: AgentContext) -> None:
        pass

    @with_prompt_template
    async def run(self, instruction: str, environment: BaseEnvironment, context: AgentContext) -> None:
        env = {
            "AWL_URL": os.environ["AWL_TB_URL"],
            "AWL_MODEL": os.environ["AWL_TB_MODEL"],
            "AWL_KEY": "local",  # the proxy swaps in the real key
            # The task container is the sandbox (and has no bwrap; tasks install packages).
            "AWL_SANDBOX": "off",
            "XDG_STATE_HOME": "/logs/agent/state",  # the session file comes back with the logs
        }
        await self.exec_as_agent(
            environment,
            command=(
                f"/installed-agent/awl -p {shlex.quote(instruction)} "
                ">/logs/agent/answer.md 2>/logs/agent/awl.log; rc=$?; "
                "tail -c 2000 /logs/agent/awl.log; exit $rc"
            ),
            env=env,
        )


from harbor.agents.installed.mini_swe_agent import MiniSweAgent  # noqa: E402


class MiniSweAgentFixed(MiniSweAgent):
    """Harbor's mini-swe-agent, plus the `mcp` package: litellm >= 1.10x imports it at
    startup but the install leaves it out (ModuleNotFoundError: No module named 'mcp')."""

    async def exec_as_agent(self, environment, command, *a, **kw):
        command = command.replace("--with litellm ", "--with litellm --with mcp ")
        return await super().exec_as_agent(environment, command, *a, **kw)


from harbor.agents.installed.hermes import Hermes  # noqa: E402


class HermesFixed(Hermes):
    """Harbor's Hermes adapter, for Hermes builds without the `hermes version` command
    (2026-10: "'version' is not a `hermes` command")."""

    def get_version_command(self) -> str | None:
        return 'export PATH="$HOME/.local/bin:$PATH"; hermes --version 2>/dev/null || echo unknown'

    async def exec_as_agent(self, environment, command, *a, **kw):
        command = command.replace("&& hermes version", "&& (hermes --version || hermes --help >/dev/null)")
        return await super().exec_as_agent(environment, command, *a, **kw)
