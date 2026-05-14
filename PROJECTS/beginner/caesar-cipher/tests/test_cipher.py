"""
©AngelaMos | 2026
test_cipher.py

Tests for CaesarCipher covering encryption, decryption, and brute-force cracking

Tests:
  encrypt/decrypt correctness for upper, lower, and mixed case
  non-letter preservation (spaces, punctuation, numbers)
  encrypt/decrypt roundtrip fidelity
  key validation and edge cases (zero key, negative key, alphabet wrapping)
  crack() generating all 26 shifts and locating the correct one

Connects to:
  cipher.py - the class under test
"""

import pytest

from caesar_cipher.cipher import CaesarCipher


class TestCaesarCipher:
    def test_encrypt_basic(self) -> None:
        """
        Encrypts uppercase text with key 3 and checks the shifted output
        """
        cipher = CaesarCipher(key = 3)
        assert cipher.encrypt("HELLO") == "KHOOR"

    def test_encrypt_lowercase(self) -> None:
        """
        Encrypts lowercase text and confirms lowercase output is preserved
        """
        cipher = CaesarCipher(key = 3)
        assert cipher.encrypt("hello") == "khoor"

    def test_encrypt_mixed_case(self) -> None:
        """
        Encrypts mixed-case text and confirms upper and lower shift independently
        """
        cipher = CaesarCipher(key = 3)
        assert cipher.encrypt("Hello World") == "Khoor Zruog"

    def test_encrypt_preserves_spaces(self) -> None:
        """
        Confirms spaces pass through encryption without being shifted
        """
        cipher = CaesarCipher(key = 5)
        assert cipher.encrypt("ABC XYZ") == "FGH CDE"

    def test_encrypt_preserves_punctuation(self) -> None:
        """
        Confirms commas and exclamation marks pass through encryption unchanged
        """
        cipher = CaesarCipher(key = 3)
        assert cipher.encrypt("Hello, World!") == "Khoor, Zruog!"

    def test_encrypt_preserves_numbers(self) -> None:
        """
        Confirms digits pass through encryption unchanged
        """
        cipher = CaesarCipher(key = 3)
        assert cipher.encrypt("Test123") == "Whvw123"

    def test_decrypt_basic(self) -> None:
        """
        Decrypts uppercase ciphertext back to plaintext using the matching key
        """
        cipher = CaesarCipher(key = 3)
        assert cipher.decrypt("KHOOR") == "HELLO"

    def test_decrypt_lowercase(self) -> None:
        """
        Decrypts lowercase ciphertext and confirms case is preserved in output
        """
        cipher = CaesarCipher(key = 3)
        assert cipher.decrypt("khoor") == "hello"

    def test_encrypt_decrypt_roundtrip(self) -> None:
        """
        Encrypts then decrypts a full sentence and asserts the result matches the original
        """
        cipher = CaesarCipher(key = 13)
        original = "The Quick Brown Fox Jumps Over The Lazy Dog!"
        encrypted = cipher.encrypt(original)
        decrypted = cipher.decrypt(encrypted)
        assert decrypted == original

    def test_key_wrapping(self) -> None:
        """
        Confirms key 26 is equivalent to key 0 and produces no shift
        """
        cipher = CaesarCipher(key = 26)
        assert cipher.encrypt("ABC") == "ABC"

    def test_negative_key(self) -> None:
        """
        Confirms a negative key shifts letters backward through the alphabet
        """
        cipher = CaesarCipher(key = -3)
        assert cipher.encrypt("HELLO") == "EBIIL"

    def test_zero_key(self) -> None:
        """
        Confirms key 0 leaves the plaintext completely unchanged
        """
        cipher = CaesarCipher(key = 0)
        assert cipher.encrypt("HELLO") == "HELLO"

    def test_key_validation_too_large(self) -> None:
        """
        Confirms keys above 26 raise ValueError with the expected message
        """
        with pytest.raises(ValueError, match = "Key must be between -25 and 26"):
            CaesarCipher(key = 30)

    def test_key_validation_too_small(self) -> None:
        """
        Confirms keys below -25 raise ValueError with the expected message
        """
        with pytest.raises(ValueError, match = "Key must be between -25 and 26"):
            CaesarCipher(key = -30)

    def test_crack_returns_all_shifts(self) -> None:
        """
        Confirms crack() produces exactly 26 candidate decryptions
        """
        results = CaesarCipher.crack("KHOOR")
        assert len(results) == 26

    def test_crack_finds_correct_shift(self) -> None:
        """
        Confirms the known shift key appears in crack() output with the correct plaintext
        """
        cipher = CaesarCipher(key = 3)
        encrypted = cipher.encrypt("HELLO")
        results = CaesarCipher.crack(encrypted)
        shifts_dict = dict(results)
        assert shifts_dict[3] == "HELLO"

    def test_empty_string(self) -> None:
        """
        Confirms empty string input returns empty string for both encrypt and decrypt
        """
        cipher = CaesarCipher(key = 3)
        assert cipher.encrypt("") == ""
        assert cipher.decrypt("") == ""

    def test_alphabet_wraparound_uppercase(self) -> None:
        """
        Confirms XYZ wraps around to ABC when shifted forward by 3
        """
        cipher = CaesarCipher(key = 3)
        assert cipher.encrypt("XYZ") == "ABC"

    def test_alphabet_wraparound_lowercase(self) -> None:
        """
        Confirms xyz wraps around to abc when shifted forward by 3
        """
        cipher = CaesarCipher(key = 3)
        assert cipher.encrypt("xyz") == "abc"
