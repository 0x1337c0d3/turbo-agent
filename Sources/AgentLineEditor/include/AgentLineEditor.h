/// Reads one prompt. The caller owns the returned allocation (free with free()).
char *agent_read_prompt(const char *prompt, const char *history_path);

/// Redraw the transcript and leave the cursor at the new prompt origin.
/// Return nonzero if redrawn. action is 0 (toggle), -1 (page up), +1 (page down).
typedef int (*agent_transcript_action)(int action, int prompt_rows);
char *agent_read_prompt_with_transcript(const char *prompt, const char *history_path,
                                      agent_transcript_action action);
