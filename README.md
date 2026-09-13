# Orchestration Harness

🎥 **[Watch the 2-Minute Project Demo](https://drive.google.com/file/d/1emXolZscY9rt3oSobPU_-VsR_RBsO_P0/view?usp=sharing)** *(Video is public for judges!)*


https://github.com/user-attachments/assets/42dbe49b-6c4b-40e9-80f7-b74bfffbebbd


An agentic, skill-driven, loop-based orchestrator that turns Slack into your primary developer workspace. By connecting **Slack**, **Notion**, and **GitHub**, this harness allows you to perform code-level changes on any targeted repository directly through chat - eliminating the need to open an IDE.

---

## 💡 Project Overview

The **Orchestration Harness** acts as an autonomous developer agent controlled entirely via Slack messages or channel interactions. 

* **Zero-Code Core:** The entire harness repository consists purely of Markdown (`.md`) files that guide local AI CLI agents (e.g., Claude CLI, Gemini CLI, or Codex) to execute orchestration logic.
* **Slack Workstation:** Message the bot directly or add it to channels. It reads conversation history, processes instructions, and executes code updates.
* **Notion Task Tracking:** Every incoming Slack message automatically generates and syncs with a Notion Database ticket.
* **Autonomous Execution:** Supports slash commands, agentic loops, and auto-prompting so the agent can continue working autonomously on production tasks while you are away.
* **Cost-Efficient:** Runs locally via LLM CLIs (Claude CLI, Gemini CLI / Antigravity) without requiring paid API keys, while still supporting custom LLM API keys if preferred.
* **Real-time or Polled:** Supports polling out of the box, with full WebSocket support in the Slack App setup for instant responses.

---

## 🛠️ External Apps & Integrations Used

* **Slack App:** Acts as the primary interface for sending commands, tracking context, and receiving status updates via direct messages or channels (supports WebSockets for real-time response).
* **Notion (Notion DB):** Serves as the centralized task management system where tickets are automatically created and updated for every request.
* **GitHub:** Target repository host where the agent clones, inspects, modifies, and commits code-level changes.

---

## 🚀 Setup Instructions

Because this repository uses a self-bootstrapping, MD-driven framework, your local LLM agent will guide you through the entire configuration.

### Fast Onboarding (New Team Members)

1. Open a **Claude Code**, **Gemini CLI**, or **Codex** session in your terminal.
2. Run the following command:

```bash
🛠️ git clone hhttps://github.com/umxcreations/orchestrator-v2/ && cd orchestration-harness-v2

Paste this command directly into your AI CLI session:

🛠️ Run harness/skills/setup.md

The agent will walk you step-by-step through:

Credentials Setup: Connecting Slack App, Notion API, and GitHub tokens.

Database Creation: Setting up the Notion Database schema.

Target Mapping: Targeting your desired GitHub repository.

Execution Options: Configuring settings (e.g., bypassing local permission prompts for autonomous mode).

Verification: Sending a test ticket to verify the end-to-end pipeline.

Already set up? Open your LLM CLI inside the harness directory and run /setup to reconfigure or update settings.

🧪 Testing Reliability
The harness has been validated through the following end-to-end test scenarios:

Event Queueing & Polling Reliability: Verified that Slack messages correctly trigger Notion ticket creation without missing events during simultaneous user inputs.

Context Preservation: Confirmed that the agent successfully reads Slack channel history to maintain full context before performing code modifications.

Autonomous Execution & Self-Prompting: Tested agentic loop behavior by dispatching long-running tasks and verifying that auto-prompting correctly advances task states in Notion until completion.

Local CLI Execution: Verified that code changes are safely executed locally via Claude/Gemini CLI, bypassing manual IDE editing and successfully pushing updates back to GitHub.
