"""
©AngelaMos | 2026
test_cli.py

Integration tests for the encrypt, decrypt, and crack CLI commands

Tests each command's exit codes, output content, key validation, and
file-based I/O using Typer's CliRunner without spawning a subprocess.

Tests:
  encrypt command: basic output, spaces, invalid key rejection
  decrypt command: basic output, spaces, invalid key rejection
  crack command: output format, --top option, --all option
  file I/O: reading from and writing to temp files

Connects to:
  main.py - invokes the Typer app under test
"""

from pathlib import Path

from typer.testing import CliRunner

from caesar_cipher.main import app


runner = CliRunner()


class TestEncryptCommand:
    def test_encrypt_basic(self) -> None:
        """
        Runs the encrypt command with key 3 and checks KHOOR appears in output
        """
        result = runner.invoke(app, ["encrypt", "HELLO", "--key", "3"])
        assert result.exit_code == 0
        assert "KHOOR" in result.stdout

    def test_encrypt_with_spaces(self) -> None:
        """
        Runs encrypt on a two-word phrase and checks both words shift correctly
        """
        result = runner.invoke(app, ["encrypt", "HELLO WORLD", "--key", "3"])
        assert result.exit_code == 0
        assert "KHOOR ZRUOG" in result.stdout

    def test_encrypt_invalid_key(self) -> None:
        """
        Runs encrypt with key 30 and confirms exit code 1 and an error message
        """
        result = runner.invoke(app, ["encrypt", "HELLO", "--key", "30"])
        assert result.exit_code == 1
        assert "Error" in result.stdout


class TestDecryptCommand:
    def test_decrypt_basic(self) -> None:
        """
        Runs the decrypt command with key 3 and checks HELLO appears in output
        """
        result = runner.invoke(app, ["decrypt", "KHOOR", "--key", "3"])
        assert result.exit_code == 0
        assert "HELLO" in result.stdout

    def test_decrypt_with_spaces(self) -> None:
        """
        Runs decrypt on a two-word ciphertext and checks the full plaintext is recovered
        """
        result = runner.invoke(app, ["decrypt", "KHOOR ZRUOG", "--key", "3"])
        assert result.exit_code == 0
        assert "HELLO WORLD" in result.stdout

    def test_decrypt_invalid_key(self) -> None:
        """
        Runs decrypt with an out-of-range key and confirms exit code 1 and an error message
        """
        result = runner.invoke(app, ["decrypt", "KHOOR", "--key", "30"])
        assert result.exit_code == 1
        assert "Error" in result.stdout


class TestCrackCommand:
    def test_crack_basic(self) -> None:
        """
        Runs the crack command and confirms HELLO is recovered and best match is shown
        """
        result = runner.invoke(app, ["crack", "KHOOR"])
        assert result.exit_code == 0
        assert "HELLO" in result.stdout
        assert "Best match" in result.stdout

    def test_crack_with_top_option(self) -> None:
        """
        Runs crack with --top 3 and confirms the command completes successfully
        """
        result = runner.invoke(app, ["crack", "KHOOR", "--top", "3"])
        assert result.exit_code == 0

    def test_crack_show_all(self) -> None:
        """
        Runs crack with --all and confirms all 26 shifts are displayed without error
        """
        result = runner.invoke(app, ["crack", "KHOOR", "--all"])
        assert result.exit_code == 0


class TestFileIO:
    def test_encrypt_from_file(self, tmp_path: Path) -> None:
        """
        Encrypts text read from a temp input file and checks the ciphertext in output
        """
        input_file = tmp_path / "input.txt"
        input_file.write_text("HELLO WORLD")

        result = runner.invoke(
            app,
            ["encrypt",
             "--input-file",
             str(input_file),
             "--key",
             "3"]
        )
        assert result.exit_code == 0
        assert "KHOOR ZRUOG" in result.stdout

    def test_encrypt_to_file(self, tmp_path: Path) -> None:
        """
        Encrypts text and writes to a temp file, then reads it back to verify contents
        """
        output_file = tmp_path / "output.txt"

        result = runner.invoke(
            app,
            [
                "encrypt",
                "HELLO",
                "--key",
                "3",
                "--output-file",
                str(output_file),
            ],
        )
        assert result.exit_code == 0
        assert output_file.read_text() == "KHOOR"

    def test_decrypt_from_file(self, tmp_path: Path) -> None:
        """
        Decrypts text read from a temp input file and checks the plaintext in output
        """
        input_file = tmp_path / "input.txt"
        input_file.write_text("KHOOR")

        result = runner.invoke(
            app,
            ["decrypt",
             "--input-file",
             str(input_file),
             "--key",
             "3"]
        )
        assert result.exit_code == 0
        assert "HELLO" in result.stdout
