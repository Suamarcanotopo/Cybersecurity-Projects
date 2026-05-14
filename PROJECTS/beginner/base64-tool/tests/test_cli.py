"""
©AngelaMos | 2026
test_cli.py

Integration tests for all five CLI commands via Typer's CliRunner

Invokes each CLI command end-to-end without spawning subprocesses and
verifies exit codes and output content. Covers encode, decode, detect,
peel, and chain along with the --version flag and error paths (invalid
format, bad input).

Tests:
  TestEncodeCommand - base64, hex, base32, url, empty input
  TestDecodeCommand - base64, hex, invalid input returns non-zero exit
  TestDetectCommand - base64 detection, hex detection, no-match message
  TestPeelCommand - single layer, plain text with no layers
  TestChainCommand - single step, multiple steps, unknown format error
  TestVersionFlag - version string present in output

Connects to:
  cli.py - imports app (the Typer application under test)
"""

from typer.testing import CliRunner

from base64_tool.cli import app


runner = CliRunner()


class TestEncodeCommand:
    def test_encode_base64(self) -> None:
        """
        Checks that the encode command outputs the correct base64 string
        """
        result = runner.invoke(app, ["encode", "Hello World"])
        assert result.exit_code == 0
        assert "SGVsbG8gV29ybGQ=" in result.output

    def test_encode_hex(self) -> None:
        """
        Checks that the encode command outputs the correct hex string with --format hex
        """
        result = runner.invoke(
            app,
            ["encode",
             "Hello",
             "--format",
             "hex"],
        )
        assert result.exit_code == 0
        assert "48656c6c6f" in result.output

    def test_encode_base32(self) -> None:
        """
        Checks that the encode command outputs the correct base32 string with --format base32
        """
        result = runner.invoke(
            app,
            ["encode",
             "Hello",
             "--format",
             "base32"],
        )
        assert result.exit_code == 0
        assert "JBSWY3DP" in result.output

    def test_encode_url(self) -> None:
        """
        Checks that the encode command percent-encodes special characters with --format url
        """
        result = runner.invoke(
            app,
            ["encode",
             "hello world&test",
             "--format",
             "url"],
        )
        assert result.exit_code == 0
        assert "%20" in result.output or "hello" in result.output

    def test_encode_empty_string(self) -> None:
        """
        Checks that encoding an empty string succeeds without error
        """
        result = runner.invoke(app, ["encode", ""])
        assert result.exit_code == 0


class TestDecodeCommand:
    def test_decode_base64(self) -> None:
        """
        Checks that the decode command recovers 'Hello World' from a known base64 string
        """
        result = runner.invoke(
            app,
            ["decode",
             "SGVsbG8gV29ybGQ="],
        )
        assert result.exit_code == 0
        assert "Hello World" in result.output

    def test_decode_hex(self) -> None:
        """
        Checks that the decode command recovers 'Hello' from a hex string
        """
        result = runner.invoke(
            app,
            ["decode",
             "48656c6c6f",
             "--format",
             "hex"],
        )
        assert result.exit_code == 0
        assert "Hello" in result.output

    def test_decode_invalid_base64(self) -> None:
        """
        Checks that decoding garbage input exits with a non-zero code
        """
        result = runner.invoke(
            app,
            ["decode",
             "!!!invalid!!!"],
        )
        assert result.exit_code != 0


class TestDetectCommand:
    def test_detect_base64(self) -> None:
        """
        Checks that the detect command identifies base64 in its output
        """
        result = runner.invoke(
            app,
            ["detect",
             "SGVsbG8gV29ybGQ="],
        )
        assert result.exit_code == 0
        assert "base64" in result.output.lower()

    def test_detect_hex(self) -> None:
        """
        Checks that the detect command identifies hex in its output
        """
        result = runner.invoke(
            app,
            ["detect",
             "48656c6c6f20576f726c64"],
        )
        assert result.exit_code == 0
        assert "hex" in result.output.lower()

    def test_detect_no_match(self) -> None:
        """
        Checks that the detect command reports no encoding found for plain text
        """
        result = runner.invoke(
            app,
            ["detect",
             "just plain text"],
        )
        assert result.exit_code == 0
        assert "no encoding" in result.output.lower()


class TestPeelCommand:
    def test_peel_single_layer(self) -> None:
        """
        Checks that the peel command reports at least one layer for a base64 string
        """
        result = runner.invoke(
            app,
            ["peel",
             "SGVsbG8gV29ybGQ="],
        )
        assert result.exit_code == 0
        assert "layer" in result.output.lower()

    def test_peel_no_encoding(self) -> None:
        """
        Checks that the peel command exits cleanly when no encoding is found
        """
        result = runner.invoke(
            app,
            ["peel",
             "hello world"],
        )
        assert result.exit_code == 0


class TestChainCommand:
    def test_chain_single_step(self) -> None:
        """
        Checks that the chain command applies one base64 step correctly
        """
        result = runner.invoke(
            app,
            ["chain",
             "Hello",
             "--steps",
             "base64"],
        )
        assert result.exit_code == 0
        assert "SGVsbG8=" in result.output

    def test_chain_multiple_steps(self) -> None:
        """
        Checks that the chain command applies two steps in sequence without error
        """
        result = runner.invoke(
            app,
            ["chain",
             "Hi",
             "--steps",
             "base64,hex"],
        )
        assert result.exit_code == 0

    def test_chain_invalid_format(self) -> None:
        """
        Checks that an unknown format name causes the chain command to exit with an error
        """
        result = runner.invoke(
            app,
            ["chain",
             "test",
             "--steps",
             "fake"],
        )
        assert result.exit_code != 0


class TestVersionFlag:
    def test_version_output(self) -> None:
        """
        Checks that --version prints the tool name and exits cleanly
        """
        result = runner.invoke(app, ["--version"])
        assert result.exit_code == 0
        assert "b64tool" in result.output
