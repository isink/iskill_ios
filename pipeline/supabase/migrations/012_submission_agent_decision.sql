-- Add half-automated agent recommendation fields to `submissions`.
--
-- The review-agent (pipeline/agents/review-agent/agent.py) writes its
-- approve/reject suggestion here. The `status` column stays untouched
-- until a human applies the decision via `npm run review:apply`.

ALTER TABLE submissions
  ADD COLUMN IF NOT EXISTS agent_decision     text
    CHECK (agent_decision IN ('approve', 'reject')),
  ADD COLUMN IF NOT EXISTS agent_reason       text,
  ADD COLUMN IF NOT EXISTS agent_reviewed_at  timestamptz;

-- Speed up the agent's "what's still mine to look at" query.
CREATE INDEX IF NOT EXISTS submissions_pending_no_agent_idx
  ON submissions (created_at)
  WHERE status = 'pending' AND agent_decision IS NULL;
