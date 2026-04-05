"""
apfel Integration Tests — CLI E2E

Exercises the release binary as a real UNIX tool:
- help/version/exit codes
- ANSI vs NO_COLOR under a TTY
- direct prompt, piped stdin, streaming, and quiet JSON output

Run via Tests/integration/run_tests.sh after the release binary has been built.
"""

import functools
import json
import os
import pathlib
import pty
import re
import select
import signal
import subprocess
import time
import warnings

import pytest


ROOT = pathlib.Path(__file__).resolve().parents[2]
BINARY = ROOT / ".build" / "release" / "apfel"
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def run_cli(args, input_text=None, env=None, timeout=60):
    merged_env = os.environ.copy()
    for key in [
        "NO_COLOR",
        "APFEL_SYSTEM_PROMPT",
        "APFEL_HOST",
        "APFEL_PORT",
        "APFEL_TEMPERATURE",
        "APFEL_MAX_TOKENS",
    ]:
        merged_env.pop(key, None)
    if env:
        merged_env.update(env)
    return subprocess.run(
        [str(BINARY), *args],
        input=input_text,
        text=True,
        capture_output=True,
        env=merged_env,
        timeout=timeout,
    )


def run_cli_tty(args, env=None, timeout=30):
    merged_env = os.environ.copy()
    for key in [
        "NO_COLOR",
        "APFEL_SYSTEM_PROMPT",
        "APFEL_HOST",
        "APFEL_PORT",
        "APFEL_TEMPERATURE",
        "APFEL_MAX_TOKENS",
    ]:
        merged_env.pop(key, None)
    if env:
        merged_env.update(env)

    master_fd, slave_fd = pty.openpty()
    proc = subprocess.Popen(
        [str(BINARY), *args],
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        env=merged_env,
        close_fds=True,
    )
    os.close(slave_fd)

    output = bytearray()
    deadline = time.time() + timeout
    try:
        while True:
            if time.time() > deadline:
                proc.kill()
                raise TimeoutError(f"Timed out waiting for {' '.join(args)}")

            ready, _, _ = select.select([master_fd], [], [], 0.1)
            if master_fd in ready:
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                output.extend(chunk)

            if proc.poll() is not None and master_fd not in ready:
                break
    finally:
        os.close(master_fd)

    proc.wait(timeout=max(1, int(deadline - time.time())))
    return proc.returncode, output.decode("utf-8", errors="replace")


def run_cli_chat_json(args, steps, env=None, timeout=60, stop_when=None):
    merged_env = os.environ.copy()
    for key in [
        "NO_COLOR",
        "APFEL_SYSTEM_PROMPT",
        "APFEL_HOST",
        "APFEL_PORT",
        "APFEL_TEMPERATURE",
        "APFEL_MAX_TOKENS",
    ]:
        merged_env.pop(key, None)
    if env:
        merged_env.update(env)

    stdout_read_fd, stdout_write_fd = os.pipe()
    with warnings.catch_warnings():
        warnings.filterwarnings(
            "ignore",
            message="This process .* use of forkpty\\(\\) may lead to deadlocks in the child\\.",
            category=DeprecationWarning,
        )
        pid, master_fd = pty.fork()
    if pid == 0:
        os.close(stdout_read_fd)
        os.dup2(stdout_write_fd, 1)
        if stdout_write_fd != 1:
            os.close(stdout_write_fd)
        os.execve(str(BINARY), [str(BINARY), *args], merged_env)

    os.close(stdout_write_fd)
    stdout_output = bytearray()
    tty_output = bytearray()
    deadline = time.time() + timeout
    pending_steps = list(steps)
    exit_status = None

    try:
        while True:
            if time.time() > deadline:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
                raise TimeoutError(f"Timed out waiting for {' '.join(args)}")

            if pending_steps:
                step = pending_steps[0]
                if len(step) == 2:
                    wait_for, data = step
                    delay = 0
                else:
                    wait_for, data, delay = step
                haystacks = (stdout_output, tty_output)
                if wait_for is None or any(wait_for in output for output in haystacks):
                    if delay:
                        time.sleep(delay)
                    os.write(master_fd, data)
                    pending_steps.pop(0)
                    continue

            ready, _, _ = select.select([master_fd, stdout_read_fd], [], [], 0.1)
            for fd in ready:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    chunk = b""
                if not chunk:
                    continue
                if fd == master_fd:
                    tty_output.extend(chunk)
                else:
                    stdout_output.extend(chunk)

            if stop_when is not None and stop_when(stdout_output, tty_output):
                os.kill(pid, signal.SIGKILL)
                _, exit_status = os.waitpid(pid, 0)
                break

            waited_pid, status = os.waitpid(pid, os.WNOHANG)
            if waited_pid == pid and not ready:
                exit_status = status
                break
    finally:
        os.close(master_fd)
        os.close(stdout_read_fd)

    if exit_status is None:
        _, exit_status = os.waitpid(pid, 0)

    return (
        os.waitstatus_to_exitcode(exit_status),
        stdout_output.decode("utf-8", errors="replace"),
        tty_output.decode("utf-8", errors="replace"),
    )


def run_cli_chat_tty(args, steps, env=None, timeout=60, stop_when=None):
    merged_env = os.environ.copy()
    for key in [
        "NO_COLOR",
        "APFEL_SYSTEM_PROMPT",
        "APFEL_HOST",
        "APFEL_PORT",
        "APFEL_TEMPERATURE",
        "APFEL_MAX_TOKENS",
    ]:
        merged_env.pop(key, None)
    if env:
        merged_env.update(env)

    with warnings.catch_warnings():
        warnings.filterwarnings(
            "ignore",
            message="This process .* use of forkpty\\(\\) may lead to deadlocks in the child\\.",
            category=DeprecationWarning,
        )
        pid, master_fd = pty.fork()
    if pid == 0:
        os.execve(str(BINARY), [str(BINARY), *args], merged_env)

    output = bytearray()
    deadline = time.time() + timeout
    pending_steps = list(steps)
    exit_status = None

    try:
        while True:
            if time.time() > deadline:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
                raise TimeoutError(f"Timed out waiting for {' '.join(args)}")

            if pending_steps:
                step = pending_steps[0]
                if len(step) == 2:
                    wait_for, data = step
                    delay = 0
                else:
                    wait_for, data, delay = step
                if wait_for is None or wait_for in output:
                    if delay:
                        time.sleep(delay)
                    os.write(master_fd, data)
                    pending_steps.pop(0)
                    continue

            ready, _, _ = select.select([master_fd], [], [], 0.1)
            if master_fd in ready:
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError:
                    chunk = b""
                if chunk:
                    output.extend(chunk)

            if stop_when is not None and stop_when(output):
                os.kill(pid, signal.SIGKILL)
                _, exit_status = os.waitpid(pid, 0)
                break

            waited_pid, status = os.waitpid(pid, os.WNOHANG)
            if waited_pid == pid and master_fd not in ready:
                exit_status = status
                break
    finally:
        os.close(master_fd)

    if exit_status is None:
        _, exit_status = os.waitpid(pid, 0)

    return os.waitstatus_to_exitcode(exit_status), output.decode("utf-8", errors="replace")


def parse_json_lines(text):
    return [json.loads(line) for line in text.splitlines() if line.strip()]


def parse_json_lines_from_output(text):
    return [json.loads(line) for line in text.splitlines() if line.lstrip().startswith("{")]


@functools.lru_cache(maxsize=1)
def model_available():
    result = run_cli(["--model-info"], timeout=20)
    return result.returncode == 0 and "available:  yes" in result.stdout.lower()


def require_model():
    if not model_available():
        pytest.skip("Apple Intelligence is not enabled for CLI generation tests.")


def test_release_binary_exists():
    assert BINARY.exists(), f"Expected release binary at {BINARY}"


def test_help_exit_success():
    result = run_cli(["--help"])
    assert result.returncode == 0
    assert "USAGE:" in result.stdout


def test_version_exit_success():
    result = run_cli(["--version"])
    assert result.returncode == 0
    assert result.stdout.startswith("apfel v")


def test_invalid_flag_exit_code():
    result = run_cli(["--definitely-not-a-real-flag"])
    assert result.returncode == 2
    assert "unknown option" in result.stderr


def test_help_uses_ansi_under_tty():
    returncode, output = run_cli_tty(["--help"])
    assert returncode == 0
    assert ANSI_RE.search(output), output


def test_no_color_disables_ansi_under_tty():
    returncode, output = run_cli_tty(["--help"], env={"NO_COLOR": "1"})
    assert returncode == 0
    assert not ANSI_RE.search(output), output


def test_quiet_json_prompt_output_is_machine_readable():
    require_model()
    result = run_cli(
        ["-q", "-o", "json", "What is 2+2? Reply with just the number."],
        timeout=90,
    )
    assert result.returncode == 0
    payload = json.loads(result.stdout)
    assert payload["model"] == "apple-foundationmodel"
    assert payload["content"].strip()
    assert result.stderr == ""


def test_piped_stdin_json_output_is_machine_readable():
    require_model()
    result = run_cli(
        ["-q", "-o", "json"],
        input_text="What is 2+2? Reply with just the number.",
        timeout=90,
    )
    assert result.returncode == 0
    payload = json.loads(result.stdout)
    assert payload["model"] == "apple-foundationmodel"
    assert payload["content"].strip()
    assert result.stderr == ""


def test_json_output_no_trailing_newline():
    """Regression: --json piped output must not end with a newline (GH-9)."""
    require_model()
    result = run_cli(
        ["-q", "-o", "json", "What is 2+2? Reply with just the number."],
        timeout=90,
    )
    assert result.returncode == 0
    assert not result.stdout.endswith("\n"), (
        f"JSON stdout ends with trailing newline: {result.stdout!r}"
    )
    # Ensure the output is still valid JSON
    json.loads(result.stdout)


def test_stream_returns_content():
    require_model()
    result = run_cli(["--stream", "Reply with the single word OK."], timeout=90)
    assert result.returncode == 0
    assert result.stdout.strip()


def test_chat_json_left_arrow_edits_input():
    require_model()
    returncode, output = run_cli_chat_tty(
        ["--chat", "-o", "json", "--max-tokens", "1"],
        steps=[
            (b"you\xe2\x80\xba ", b"helo\x1b[D\x1b[Dl\n", 0.2),
        ],
        stop_when=lambda output: output.count(b'"role":"user"') >= 1,
    )
    assert returncode != 0
    messages = parse_json_lines_from_output(output)
    user_messages = [message for message in messages if message["role"] == "user"]
    assert user_messages[0]["content"] == "hello"
    assert "^[[D" not in output
    assert "\x1b[D" not in output


def test_chat_json_up_arrow_replays_previous_prompt():
    require_model()
    first_prompt = "Reply ALPHA."
    returncode, output = run_cli_chat_tty(
        ["--chat", "-o", "json", "--max-tokens", "1"],
        steps=[
            (b"you\xe2\x80\xba ", f"{first_prompt}\n\x1b[A\n".encode("utf-8"), 0.2),
        ],
        stop_when=lambda output: output.count(b'"role":"user"') >= 2,
    )
    assert returncode != 0
    messages = parse_json_lines_from_output(output)
    user_messages = [message for message in messages if message["role"] == "user"]
    assert [message["content"] for message in user_messages[:2]] == [
        first_prompt,
        first_prompt,
    ]


def test_chat_json_keeps_prompt_chrome_off_stdout():
    require_model()
    returncode, stdout, tty = run_cli_chat_json(
        ["--chat", "-o", "json", "--max-tokens", "1"],
        steps=[
            (b"Type 'quit' to exit.", b"Hello\n", 0.2),
        ],
        stop_when=lambda stdout, _tty: stdout.count(b'"role":"user"') >= 1,
    )
    assert returncode != 0
    messages = parse_json_lines(stdout)
    assert [message["role"] for message in messages] == ["user"]
    assert messages[0]["content"] == "Hello"
    assert "Type 'quit' to exit." not in stdout
    assert "you› " not in stdout
    assert "Type 'quit' to exit." in tty


def _assert_system_prompt_honored(args):
    require_model()
    system_prompt = "You are a pirate. Reply in pirate speech and include matey or arrr."
    command = [
        system_prompt if arg == "__SYSTEM_PROMPT__" else arg
        for arg in args
    ]
    result = run_cli(["-q", "-o", "json", *command], timeout=90)
    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    content = payload["content"].lower()
    assert "matey" in content or "arrr" in content or "arr" in content, payload["content"]


def test_system_prompt_controls_non_stream_prompt():
    _assert_system_prompt_honored(["-s", "__SYSTEM_PROMPT__", "What is recursion?"])


def test_system_prompt_is_honored_with_stream_after_short_flag():
    _assert_system_prompt_honored(["-s", "__SYSTEM_PROMPT__", "--stream", "What is recursion?"])


def test_system_prompt_is_honored_with_stream_before_short_flag():
    _assert_system_prompt_honored(["--stream", "-s", "__SYSTEM_PROMPT__", "What is recursion?"])


# --- File flag (-f/--file) tests (GH-12) ---


def test_help_shows_file_flag():
    result = run_cli(["--help"])
    assert result.returncode == 0
    assert "--file" in result.stdout
    assert "-f," in result.stdout


def test_file_flag_missing_path():
    result = run_cli(["-f"])
    assert result.returncode == 2
    assert "requires a file path" in result.stderr


def test_file_flag_nonexistent_file():
    result = run_cli(["-f", "/tmp/apfel_no_such_file_ever.txt", "summarize"])
    assert result.returncode == 2
    assert "no such file" in result.stderr


def test_file_flag_with_prompt():
    """apfel -f <file> <prompt> should prepend file content to the prompt."""
    require_model()
    tmp = pathlib.Path("/tmp/apfel_test_file_flag.txt")
    tmp.write_text("The capital of Austria is Vienna.")
    try:
        result = run_cli(
            ["-q", "-o", "json", "-f", str(tmp), "What city is mentioned? Reply with just the city name."],
            timeout=90,
        )
        assert result.returncode == 0
        payload = json.loads(result.stdout)
        assert "vienna" in payload["content"].lower()
    finally:
        tmp.unlink(missing_ok=True)


def test_file_flag_no_prompt():
    """apfel -f <file> with no prompt argument should use file content as the prompt."""
    require_model()
    tmp = pathlib.Path("/tmp/apfel_test_file_noprompt.txt")
    tmp.write_text("What is 2+2? Reply with just the number.")
    try:
        result = run_cli(
            ["-q", "-o", "json", "-f", str(tmp)],
            timeout=90,
        )
        assert result.returncode == 0
        payload = json.loads(result.stdout)
        assert payload["content"].strip()
    finally:
        tmp.unlink(missing_ok=True)


def test_multiple_file_flags():
    """apfel -f a.txt -f b.txt <prompt> should include content from both files."""
    require_model()
    tmp_a = pathlib.Path("/tmp/apfel_test_multi_a.txt")
    tmp_b = pathlib.Path("/tmp/apfel_test_multi_b.txt")
    tmp_a.write_text("Fact A: The sky is blue.")
    tmp_b.write_text("Fact B: Grass is green.")
    try:
        result = run_cli(
            ["-q", "-o", "json", "-f", str(tmp_a), "-f", str(tmp_b),
             "List both facts. Reply with just the two facts, one per line."],
            timeout=90,
        )
        assert result.returncode == 0
        payload = json.loads(result.stdout)
        content = payload["content"].lower()
        assert "blue" in content
        assert "green" in content
    finally:
        tmp_a.unlink(missing_ok=True)
        tmp_b.unlink(missing_ok=True)


def test_stdin_with_prompt_argument():
    """Piped stdin + prompt argument should combine (stdin prepended to prompt)."""
    require_model()
    result = run_cli(
        ["-q", "-o", "json", "What city is mentioned above? Reply with just the city name."],
        input_text="The capital of France is Paris.",
        timeout=90,
    )
    assert result.returncode == 0
    payload = json.loads(result.stdout)
    assert "paris" in payload["content"].lower()


def test_file_flag_with_stdin_and_prompt():
    """apfel -f <file> <prompt> with piped stdin should include all three."""
    require_model()
    tmp = pathlib.Path("/tmp/apfel_test_file_stdin.txt")
    tmp.write_text("File content: The answer is 42.")
    try:
        result = run_cli(
            ["-q", "-o", "json", "-f", str(tmp),
             "What number is mentioned? Reply with just the number."],
            input_text="Stdin content: ignore this.",
            timeout=90,
        )
        assert result.returncode == 0
        payload = json.loads(result.stdout)
        assert "42" in payload["content"]
    finally:
        tmp.unlink(missing_ok=True)


# --- Self-update tests (--update) ---


def test_update_flag_exits_success():
    """--update should exit 0 regardless of install method."""
    result = run_cli(["--update"])
    assert result.returncode == 0


def test_update_shows_version():
    """--update output should contain the current version."""
    result = run_cli(["--update"])
    assert "apfel v" in result.stdout


def test_update_detects_install_method():
    """--update should identify either 'Homebrew' or 'from source'."""
    result = run_cli(["--update"])
    assert "Homebrew" in result.stdout or "from source" in result.stdout


def test_update_in_help():
    """--update should appear in the help text."""
    result = run_cli(["--help"])
    assert "--update" in result.stdout


def test_update_non_interactive():
    """--update with piped stdin should not hang waiting for input."""
    result = run_cli(["--update"], input_text="", timeout=30)
    assert result.returncode == 0


# --- README CLI Reference completeness test ---


def test_readme_cli_reference_complete():
    """Every flag from --help must appear in BOTH the quick-reference block AND the examples block."""
    result = run_cli(["--help"])
    assert result.returncode == 0, f"--help failed: {result.stderr}"

    # Parse flags from OPTIONS, CONTEXT OPTIONS, and SERVER OPTIONS sections only.
    flag_sections = []
    in_flag_section = False
    for line in result.stdout.splitlines():
        stripped = line.strip()
        if stripped in ("OPTIONS:", "CONTEXT OPTIONS:", "SERVER OPTIONS:"):
            in_flag_section = True
            continue
        if stripped in ("ENVIRONMENT:", "EXIT CODES:", "EXAMPLES:", "USAGE:"):
            in_flag_section = False
            continue
        if in_flag_section:
            flag_sections.append(line)

    help_flags = set(re.findall(r"--[a-z][-a-z]+", "\n".join(flag_sections)))
    assert help_flags, "Failed to extract any flags from --help output"

    # Read CLI Reference section from README
    readme_text = (ROOT / "README.md").read_text()
    cli_ref_match = re.search(
        r"^## CLI Reference\s*\n(.*?)(?=^## |\Z)",
        readme_text,
        re.MULTILINE | re.DOTALL,
    )
    assert cli_ref_match, "Could not find '## CLI Reference' section in README.md"
    cli_reference = cli_ref_match.group(1)

    # Split into the two code blocks: quick-reference (first) and examples (second)
    code_blocks = re.findall(r"```(?:bash)?\n(.*?)```", cli_reference, re.DOTALL)
    assert len(code_blocks) >= 2, (
        f"Expected at least 2 code blocks in CLI Reference (quick-ref + examples), found {len(code_blocks)}"
    )
    quick_ref = code_blocks[0]
    examples = code_blocks[1]

    # Every flag must appear in the quick-reference block
    missing_from_ref = sorted(flag for flag in help_flags if flag not in quick_ref)
    assert not missing_from_ref, (
        f"CLI Reference quick-reference block is missing {len(missing_from_ref)} flag(s):\n  "
        + "\n  ".join(missing_from_ref)
    )

    # Every flag must appear in the examples block
    missing_from_examples = sorted(flag for flag in help_flags if flag not in examples)
    assert not missing_from_examples, (
        f"CLI Reference examples block is missing {len(missing_from_examples)} flag(s):\n  "
        + "\n  ".join(missing_from_examples)
    )
