/*
 * LargeEditorFixture.c
 *
 * Deterministic characterization fixture for docs/LARGE_FILE_EDITING.md.
 * Modeled on Sources/AgentLineEditor/AgentLineEditor.c in shape and scale: a
 * libedit prompt loop with prompt state, multiline cancellation, history
 * tracking, transcript repaint, and a long key-binding table. The file is
 * never compiled; LargeFileEditingTests read it as UTF-8 text to reproduce
 * the 8K active-turn accumulation failure without any live-model dependency.
 */

#include "fixture_editor.h"
#include <histedit.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <termios.h>
#include <time.h>
#include <sys/ioctl.h>

typedef struct {
    const char *prompt;
    int cancelled;
    int edited;
    wchar_t *history_text;
    size_t history_length;
    fixture_transcript_action transcript_action;
} FixtureState;

static FixtureState *fixture_state(EditLine *editor) {
    void *state = NULL;
    el_get(editor, EL_CLIENTDATA, &state);
    return state;
}

static char *fixture_prompt_text(EditLine *editor) {
    return (char *)fixture_state(editor)->prompt;
}

static int fixture_read_character(EditLine *editor, wchar_t *character) {
    FixtureState *state = fixture_state(editor);
    const LineInfoW *line = el_wline(editor);
    size_t length = (size_t)(line->lastchar - line->buffer);
    if (length != state->history_length ||
        (length && wmemcmp(line->buffer, state->history_text, length) != 0)) {
        state->edited = 1;
    }
    // Observe each completed edit, but retain libedit's native input decoding,
    // signal handling and terminal-resize behavior.
    el_wset(editor, EL_GETCFN, EL_BUILTIN_GETCFN);
    int result = el_wgetc(editor, character);
    el_wset(editor, EL_GETCFN, fixture_read_character);
    return result;
}

static unsigned char fixture_remember_history(EditLine *editor, int key) {
    (void)key;
    FixtureState *state = fixture_state(editor);
    const LineInfoW *line = el_wline(editor);
    size_t length = (size_t)(line->lastchar - line->buffer);
    wchar_t *text = malloc((length + 1) * sizeof(*text));
    if (!text) {
        state->edited = 1;
        return CC_ERROR;
    }
    wmemcpy(text, line->buffer, length);
    text[length] = L'\0';
    free(state->history_text);
    state->history_text = text;
    state->history_length = length;
    state->edited = 0;
    return CC_NORM;
}

static unsigned char fixture_cancel_prompt(EditLine *editor, int key) {
    (void)key;
    // Finish at the bottom of a multiline draft before drawing the fresh prompt.
    el_push(editor, "\033[95~\033[96~");
    return CC_NORM;
}

static unsigned char fixture_finish_cancel(EditLine *editor, int key) {
    (void)key;
    fixture_state(editor)->cancelled = 1;
    return CC_NEWLINE;
}

static unsigned char fixture_move_line(EditLine *editor, int up) {
    const LineInfo *line = el_line(editor);
    // Private sequences dispatch to libedit's native cursor/history commands.
    int browse = line->buffer == line->lastchar || !fixture_state(editor)->edited;
    el_push(editor, browse ? (up ? "\033[91~\033[97~" : "\033[92~\033[97~")
                           : (up ? "\033[93~" : "\033[94~"));
    return CC_NORM;
}

static unsigned char fixture_move_up(EditLine *editor, int key) {
    (void)key;
    return fixture_move_line(editor, 1);
}

static unsigned char fixture_move_down(EditLine *editor, int key) {
    (void)key;
    return fixture_move_line(editor, 0);
}

static unsigned char fixture_insert_newline(EditLine *editor, int key) {
    (void)key;
    return el_insertstr(editor, "\n") == 0 ? CC_REFRESH : CC_ERROR;
}

static unsigned char fixture_delete_char(EditLine *editor, int key) {
    (void)key;
    const LineInfo *line = el_line(editor);
    if (line->buffer == line->lastchar) {
        return CC_EOF;
    }
    el_push(editor, "\033[90~");
    return CC_NORM;
}

static unsigned char fixture_move_to_boundary(EditLine *editor, int end) {
    const LineInfoW *line = el_wline(editor);
    const wchar_t *target = line->cursor;
    if (end) {
        while (target < line->lastchar && *target != L'\n') target++;
    } else {
        while (target > line->buffer && target[-1] != L'\n') target--;
    }
    size_t count = (size_t)(end ? target - line->cursor : line->cursor - target);
    if (!count) return CC_NORM;
    char *movement = malloc(count + 1);
    if (!movement) return CC_ERROR;
    // Native character motion keeps libedit's cursor and display in sync.
    memset(movement, end ? '\006' : '\002', count);
    movement[count] = '\0';
    el_push(editor, movement);
    free(movement);
    return CC_NORM;
}

static unsigned char fixture_move_to_start(EditLine *editor, int key) {
    (void)key;
    return fixture_move_to_boundary(editor, 0);
}

static unsigned char fixture_move_to_end(EditLine *editor, int key) {
    (void)key;
    return fixture_move_to_boundary(editor, 1);
}

static unsigned char fixture_delete_line(EditLine *editor, int key) {
    (void)key;
    const LineInfoW *line = el_wline(editor);
    const wchar_t *start = line->cursor;
    const wchar_t *end = line->cursor;
    while (start > line->buffer && start[-1] != L'\n') start--;
    while (end < line->lastchar && *end != L'\n') end++;

    size_t right_count = (size_t)(end - line->cursor);
    size_t left_count = (size_t)(line->cursor - start);

    // If cursor is not at line end, move to end of current line first.
    if (right_count > 0) {
        char *movement = malloc(right_count + 1);
        if (!movement) return CC_ERROR;
        memset(movement, '\006', right_count); // ^F (forward)
        movement[right_count] = '\0';
        el_push(editor, movement);
        free(movement);
    }

    // Delete all characters in the line.
    size_t total_line_chars = left_count + right_count;
    if (total_line_chars > 0) {
        el_wdeletestr(editor, (int)total_line_chars);
    }
    return CC_REFRESH;
}

static unsigned char fixture_transcript_action(EditLine *editor, int action) {
    FixtureState *state = fixture_state(editor);
    if (!state->transcript_action) return CC_NORM;
    struct winsize size;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) != 0 || size.ws_col < 2) return CC_NORM;
    // The visible prompt is "> ". Reserve its complete wrapped draft, including
    // lines after the cursor, before asking Swift to repaint the transcript.
    int rows = 1, column = 2;
    const LineInfoW *line = el_wline(editor);
    for (const wchar_t *p = line->buffer; p < line->lastchar; p++) {
        if (*p == L'\n') { rows++; column = 0; continue; }
        int width = *p == L'\t' ? 8 - column % 8 : wcwidth(*p);
        if (width < 0) width = 2;
        if (column + width > size.ws_col) { rows++; column = 0; }
        column += width;
        if (column >= size.ws_col) { rows++; column = 0; }
    }
    if (!state->transcript_action(action, rows)) return CC_NORM;
    // EL_REFRESH forgets the old screen coordinates, but retains the entire
    // editing buffer and insertion point. CC_REDISPLAY would clear old lines
    // relative to the *new* origin and erase part of the repainted transcript.
    el_set(editor, EL_REFRESH);
    return CC_NORM;
}

static unsigned char fixture_toggle_mode(EditLine *editor, int key) {
    (void)key;
    return fixture_transcript_action(editor, 2); // 2 toggles local/remote mode
}

static unsigned char fixture_toggle_tools(EditLine *editor, int key) {
    (void)key;
    return fixture_transcript_action(editor, 0);
}

static unsigned char fixture_transcript_up(EditLine *editor, int key) {
    (void)key;
    return fixture_transcript_action(editor, -1);
}

static unsigned char fixture_transcript_down(EditLine *editor, int key) {
    (void)key;
    return fixture_transcript_action(editor, 1);
}

static void fixture_bind_key(EditLine *editor, const char *key, const char *command) {
    el_set(editor, EL_BIND, key, command, NULL);
}

static void fixture_configure_keys(EditLine *editor) {
    el_set(editor, EL_ADDFN, "fixture-up", "Previous prompt line", fixture_move_up);
    el_set(editor, EL_ADDFN, "fixture-down", "Next prompt line", fixture_move_down);
    el_set(editor, EL_ADDFN, "fixture-history", "Remember recalled prompt", fixture_remember_history);
    fixture_bind_key(editor, "^[[97~", "fixture-history");
    el_set(editor, EL_ADDFN, "fixture-newline", "Insert a newline", fixture_insert_newline);
    el_set(editor, EL_ADDFN, "fixture-start", "Start of current line", fixture_move_to_start);
    el_set(editor, EL_ADDFN, "fixture-end", "End of current line", fixture_move_to_end);
    el_set(editor, EL_ADDFN, "fixture-delete-line", "Delete current line", fixture_delete_line);
    el_set(editor, EL_ADDFN, "fixture-cancel", "Clear the prompt", fixture_cancel_prompt);
    el_set(editor, EL_ADDFN, "fixture-finish-cancel", "Finish clearing the prompt", fixture_finish_cancel);
    el_set(editor, EL_ADDFN, "fixture-toggle-tools", "Expand/collapse tool responses", fixture_toggle_tools);
    el_set(editor, EL_ADDFN, "fixture-transcript-up", "Previous transcript page", fixture_transcript_up);
    el_set(editor, EL_ADDFN, "fixture-transcript-down", "Next transcript page", fixture_transcript_down);
    el_set(editor, EL_ADDFN, "fixture-toggle-mode", "Toggle local/remote mode", fixture_toggle_mode);
    fixture_bind_key(editor, "^[[Z", "fixture-toggle-mode"); // Shift-Tab
    fixture_bind_key(editor, "^[[9;2u", "fixture-toggle-mode"); // Kitty Shift-Tab
    fixture_bind_key(editor, "^[[27;2;9~", "fixture-toggle-mode"); // XTerm Shift-Tab
    fixture_bind_key(editor, "^O", "fixture-toggle-tools");
    fixture_bind_key(editor, "^[[111;5u", "fixture-toggle-tools");
    fixture_bind_key(editor, "^[[27;5;111~", "fixture-toggle-tools");
    fixture_bind_key(editor, "^[[5~", "fixture-transcript-up");
    fixture_bind_key(editor, "^[[6~", "fixture-transcript-down");
    fixture_bind_key(editor, "^[[95~", "ed-move-to-end");
    fixture_bind_key(editor, "^[[96~", "fixture-finish-cancel");
    fixture_bind_key(editor, "^C", "fixture-cancel");
    fixture_bind_key(editor, "^[[99;5u", "fixture-cancel");
    fixture_bind_key(editor, "^[[27;5;99~", "fixture-cancel");
    el_set(editor, EL_ADDFN, "fixture-delete-char", "Delete character under cursor or EOF", fixture_delete_char);
    fixture_bind_key(editor, "^[[90~", "ed-delete-next-char");
    fixture_bind_key(editor, "^D", "fixture-delete-char");
    fixture_bind_key(editor, "^[[100;5u", "fixture-delete-char");
    fixture_bind_key(editor, "^[[27;5;100~", "fixture-delete-char");
    fixture_bind_key(editor, "^[[3~", "ed-delete-next-char");
    fixture_bind_key(editor, "^[[3;5~", "ed-delete-next-char");
    fixture_bind_key(editor, "^[[3;9~", "fixture-delete-line"); // Cmd-Delete (Forward Delete)
    fixture_bind_key(editor, "^[[3;10~", "fixture-delete-line");
    fixture_bind_key(editor, "^[[3;13~", "fixture-delete-line");
    fixture_bind_key(editor, "^[[127;9u", "fixture-delete-line"); // Cmd-Delete (Kitty)
    fixture_bind_key(editor, "^[[127;10u", "fixture-delete-line");
    fixture_bind_key(editor, "^[[127;13u", "fixture-delete-line");
    fixture_bind_key(editor, "^[[8;9u", "fixture-delete-line"); // Cmd-Backspace (Kitty BS)
    fixture_bind_key(editor, "^[[8;10u", "fixture-delete-line");
    fixture_bind_key(editor, "^[[8;13u", "fixture-delete-line");
    fixture_bind_key(editor, "^[[27;9;127~", "fixture-delete-line"); // Cmd-Backspace (XTerm)
    fixture_bind_key(editor, "^[[27;13;127~", "fixture-delete-line");
    fixture_bind_key(editor, "^[[27;9;8~", "fixture-delete-line");
    fixture_bind_key(editor, "^[[27;13;8~", "fixture-delete-line");
    fixture_bind_key(editor, "^B", "ed-prev-char");
    fixture_bind_key(editor, "^[[98;5u", "ed-prev-char");
    fixture_bind_key(editor, "^[[27;5;98~", "ed-prev-char");
    fixture_bind_key(editor, "^F", "ed-next-char");
    fixture_bind_key(editor, "^[[102;5u", "ed-next-char");
    fixture_bind_key(editor, "^[[27;5;102~", "ed-next-char");
    fixture_bind_key(editor, "^W", "ed-delete-prev-word");
    fixture_bind_key(editor, "^[[119;5u", "ed-delete-prev-word");
    fixture_bind_key(editor, "^[[27;5;119~", "ed-delete-prev-word");
    fixture_bind_key(editor, "^[[119;2u", "ed-delete-prev-word");
    fixture_bind_key(editor, "^[[27;2;119~", "ed-delete-prev-word");
    fixture_bind_key(editor, "^[[119;9u", "ed-delete-prev-word");
    fixture_bind_key(editor, "^[[27;9;119~", "ed-delete-prev-word");
    fixture_bind_key(editor, "^[[3;2~", "ed-delete-prev-word");
    fixture_bind_key(editor, "^[[3;5~", "ed-delete-prev-word");
    fixture_bind_key(editor, "^K", "ed-kill-line");
    fixture_bind_key(editor, "^[[107;5u", "ed-kill-line");
    fixture_bind_key(editor, "^[[27;5;107~", "ed-kill-line");
    fixture_bind_key(editor, "^U", "vi-kill-line-prev");
    fixture_bind_key(editor, "^[[117;5u", "vi-kill-line-prev");
    fixture_bind_key(editor, "^[[27;5;117~", "vi-kill-line-prev");
    fixture_bind_key(editor, "^L", "ed-clear-screen");
    fixture_bind_key(editor, "^[[108;5u", "ed-clear-screen");
    fixture_bind_key(editor, "^[[27;5;108~", "ed-clear-screen");
    fixture_bind_key(editor, "^A", "fixture-start");
    fixture_bind_key(editor, "^E", "fixture-end");
    // Enhanced keyboard mode also changes the encoding of Ctrl shortcuts.
    fixture_bind_key(editor, "^[[97;5u", "fixture-start");
    fixture_bind_key(editor, "^[[101;5u", "fixture-end");
    fixture_bind_key(editor, "^[[27;5;97~", "fixture-start");
    fixture_bind_key(editor, "^[[27;5;101~", "fixture-end");
    fixture_bind_key(editor, "^[[91~", "ed-prev-history");
    fixture_bind_key(editor, "^[[92~", "ed-next-history");
    fixture_bind_key(editor, "^[[93~", "ed-prev-line");
    fixture_bind_key(editor, "^[[94~", "ed-next-line");
    fixture_bind_key(editor, "^[[A", "fixture-up");
    fixture_bind_key(editor, "^[OA", "fixture-up");
    fixture_bind_key(editor, "^[[B", "fixture-down");
    fixture_bind_key(editor, "^[OB", "fixture-down");
    fixture_bind_key(editor, "^[[13;2u", "fixture-newline");
    fixture_bind_key(editor, "^[[27;2;13~", "fixture-newline");
    fixture_bind_key(editor, "^J", "fixture-newline");
    fixture_bind_key(editor, "^M", "ed-newline");
}

static void fixture_prepare_terminal(EditLine *editor) {
    // Apple's libedit reapplies its flags when entering editing mode.
    el_set(editor, EL_PREP_TERM, 1);
    struct termios mode;
    if (tcgetattr(STDIN_FILENO, &mode) == 0) {
        mode.c_iflag &= ~(ICRNL | INLCR);
        // Handle Ctrl+C on the editor thread; retain other terminal signals.
        mode.c_cc[VINTR] = _POSIX_VDISABLE;
        // Ctrl+O is a UI command, never the terminal's discard-output toggle.
        mode.c_cc[VDISCARD] = _POSIX_VDISABLE;
        tcsetattr(STDIN_FILENO, TCSANOW, &mode);
    }
}

static char *fixture_read_prompt_loop(EditLine *editor, FixtureState *state) {
    double last_cancel = -10;
    for (;;) {
        fixture_prepare_terminal(editor);
        state->cancelled = 0;
        state->edited = 0;
        state->history_length = 0;
        int count = 0;
        const char *line = el_gets(editor, &count);
        if (!state->cancelled) {
            if (!line || count <= 0) return NULL;
            if (line[count - 1] == '\n') count--;
            return strndup(line, (size_t)count);
        }
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double seconds = now.tv_sec + now.tv_nsec / 1e9;
        if (seconds - last_cancel <= 3) {
            fputs("\n[Force Exited by User]\n", stdout);
            return NULL;
        }
        last_cancel = seconds;
        fputs("\n[Prompt cleared. Press ctrl-c again to exit]\n", stdout);
        fflush(stdout);
    }
}

char *fixture_read_prompt(const char *prompt, const char *history_path) {
    return fixture_read_prompt_with_transcript(prompt, history_path, NULL);
}

char *fixture_read_prompt_with_transcript(const char *prompt, const char *history_path,
                                          fixture_transcript_action action) {
    EditLine *editor = el_init("FixtureEditor", stdin, stdout, stderr);
    if (!editor) return NULL;
    History *entries = history_init();
    HistEvent event;
    if (entries) {
        history(entries, &event, H_SETSIZE, 1000);
        if (history_path) history(entries, &event, H_LOAD, history_path);
        el_set(editor, EL_HIST, history, entries);
    }
    el_set(editor, EL_EDITOR, "emacs");
    el_set(editor, EL_SIGNAL, 1);
    // libedit normally swaps CR/LF. Keep Enter and Ctrl+J distinct.
    el_set(editor, EL_SETTY, "-d", "-icrnl", "-inlcr", NULL);
    FixtureState state = {.prompt = prompt, .transcript_action = action};
    el_set(editor, EL_CLIENTDATA, &state);
    el_wset(editor, EL_GETCFN, fixture_read_character);
    el_set(editor, EL_PROMPT_ESC, fixture_prompt_text, '\001');
    fixture_configure_keys(editor);
    // Request disambiguated keys from terminals supporting the Kitty protocol.
    int enhanced = isatty(STDIN_FILENO) && isatty(STDOUT_FILENO);
    if (enhanced) { fputs("\033[>1u", stdout); fflush(stdout); }
    char *result = fixture_read_prompt_loop(editor, &state);
    if (enhanced) { fputs("\033[<u", stdout); fflush(stdout); }
    if (result) {
        if (*result && entries) {
            history(entries, &event, H_ENTER, result);
            if (history_path) history(entries, &event, H_SAVE, history_path);
        }
    }
    el_end(editor);
    free(state.history_text);
    if (entries) history_end(entries);
    return result;
}