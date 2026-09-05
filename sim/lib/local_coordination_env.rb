# frozen_string_literal: true

module LocalCoordinationEnv
  # Open3 treats nil values as deletions from the child environment.
  SCRUBBED_VARIABLES = {
    "AGENT_COORD_API_URL" => nil,
    "AGENT_COORD_API_TOKEN" => nil,
    "AGENT_COORD_BACKEND" => nil,
    "AGENT_COORD_ENV_FILE" => nil,
    "AGENT_COORD_LOCAL" => nil,
    "AGENT_COORD_MACHINE_ID" => nil,
    "AGENT_COORD_POLICY" => nil,
    "AGENT_COORD_REF" => nil,
    "AGENT_COORD_SESSION_ID" => nil,
    "AGENT_COORD_STATE_ROOT" => nil,
    "AGENT_COORD_STATUS_STATE_ROOT" => nil,
    "CODEX_THREAD_ID" => nil
  }.freeze
end
