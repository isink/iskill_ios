"""Skiller review-agent — half-automated UGC submission reviewer.

Reads pending submissions, decides approve / reject via DeepSeek + LangGraph,
writes the recommendation to `submissions.agent_decision`. Status is NOT
touched — a human applies the decision later via `npm run review:apply`.

Triggered:
  - launchctl (com.skiller.review-agent) every 4h as a fallback
  - manually after ntfy push when a new submission lands
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent / ".env")

from langchain_core.messages import HumanMessage, SystemMessage
from langchain_openai import ChatOpenAI
from langgraph.graph import MessagesState, StateGraph
from langgraph.prebuilt import ToolNode, tools_condition

from tools import (
    clone_and_locate_skills,
    fetch_pending,
    query_similar_skills,
    run_validator,
    submit_decision,
)

TOOLS = [
    fetch_pending,
    clone_and_locate_skills,
    run_validator,
    query_similar_skills,
    submit_decision,
]

SYSTEM_PROMPT = """You are the Skiller review-agent. You process pending UGC submissions of Claude-Code skill repositories and write an approve/reject recommendation to each submission row. You do NOT change submission status; a human applies your decision later.

Workflow per run:
1. Call `fetch_pending`. If the list is empty, output exactly `No pending submissions.` and stop.
2. For each submission, in order:
   a. Call `clone_and_locate_skills(github_url)`.
      - If the result has `error`, recommend reject with that error string as the reason.
      - If `packages` is empty, recommend reject: "No SKILL.md found in the repository (packages list is empty). The repo does not contain any valid skill packages at root or one level deep."
   b. Otherwise call `run_validator(package_dir)` for each package.
      - If any package fails, recommend reject with a concise reason naming the failing package and its first error.
   c. (Optional) Call `query_similar_skills(author, repo)` to flag potential duplicates. Duplicates are still approvable; just mention it in the reason.
   d. If every package passes, recommend approve. Reason should note how many packages would be ingested.
   e. Call `submit_decision(submission_id, decision, reason)` to persist the recommendation.
3. After every submission is decided, output one summary line per submission in the form:
   `recommend <approve|reject> submission <id>: <reason>`

Rules:
- Be concise. Reasons should be under ~300 characters when possible.
- Never invent skill data — only what tools return.
- If a tool errors unexpectedly, recommend reject with the tool's error text.
- Process every submission, even if earlier ones fail.
"""


def _build_graph():
    llm = ChatOpenAI(
        model=os.environ.get("DEEPSEEK_MODEL", "deepseek-chat"),
        api_key=os.environ["DEEPSEEK_API_KEY"],
        base_url=os.environ.get("DEEPSEEK_BASE_URL", "https://api.deepseek.com/v1"),
        temperature=0,
    )
    llm_with_tools = llm.bind_tools(TOOLS)

    def assistant(state: MessagesState) -> dict:
        return {"messages": [llm_with_tools.invoke(state["messages"])]}

    graph = StateGraph(MessagesState)
    graph.add_node("assistant", assistant)
    graph.add_node("tools", ToolNode(TOOLS))
    graph.set_entry_point("assistant")
    graph.add_conditional_edges("assistant", tools_condition)
    graph.add_edge("tools", "assistant")
    return graph.compile()


def _langfuse_callbacks() -> list:
    if not os.environ.get("LANGFUSE_PUBLIC_KEY"):
        return []
    try:
        from langfuse.callback import CallbackHandler  # langfuse v2
    except ImportError:
        try:
            from langfuse.langchain import CallbackHandler  # langfuse v3+
        except ImportError:
            return []
    return [CallbackHandler()]


def main() -> int:
    graph = _build_graph()
    initial = {
        "messages": [
            SystemMessage(content=SYSTEM_PROMPT),
            HumanMessage(content="Process all pending submissions."),
        ]
    }
    final = graph.invoke(
        initial,
        config={"recursion_limit": 60, "callbacks": _langfuse_callbacks()},
    )

    msgs = final.get("messages", [])
    if not msgs:
        print("agent produced no output", file=sys.stderr)
        return 1

    print()
    print("=" * 60)
    print("Final agent message:")
    print(msgs[-1].content)
    return 0


if __name__ == "__main__":
    sys.exit(main())
