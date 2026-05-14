# ===================
# ©AngelaMos | 2026
# signing_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/audit/signing"

describe CRE::Audit::Signing do
  it "generates a keypair" do
    kp = CRE::Audit::Signing::Ed25519Keypair.generate(version: 1)
    kp.private_key.size.should eq 32
    kp.public_key.size.should eq 32
    kp.version.should eq 1
  end

  it "signs and verifies a message" do
    kp = CRE::Audit::Signing::Ed25519Keypair.generate
    signer = CRE::Audit::Signing::Ed25519Signer.from_keypair(kp)
    verifier = CRE::Audit::Signing::Ed25519Verifier.new(kp.public_key)

    msg = "audit batch root".to_slice
    sig = signer.sign(msg)
    sig.size.should eq 64
    verifier.verify(msg, sig).should be_true
  end

  it "rejects tampered message" do
    kp = CRE::Audit::Signing::Ed25519Keypair.generate
    signer = CRE::Audit::Signing::Ed25519Signer.from_keypair(kp)
    verifier = CRE::Audit::Signing::Ed25519Verifier.new(kp.public_key)

    msg = "original".to_slice
    sig = signer.sign(msg)
    verifier.verify("tampered".to_slice, sig).should be_false
  end

  it "rejects tampered signature" do
    kp = CRE::Audit::Signing::Ed25519Keypair.generate
    signer = CRE::Audit::Signing::Ed25519Signer.from_keypair(kp)
    verifier = CRE::Audit::Signing::Ed25519Verifier.new(kp.public_key)

    msg = "x".to_slice
    sig = signer.sign(msg)
    sig[0] ^= 0x01_u8
    verifier.verify(msg, sig).should be_false
  end

  it "two keypairs produce different keys" do
    a = CRE::Audit::Signing::Ed25519Keypair.generate
    b = CRE::Audit::Signing::Ed25519Keypair.generate
    a.private_key.should_not eq b.private_key
    a.public_key.should_not eq b.public_key
  end
end
