# ©AngelaMos | 2026
# Justfile

set shell := ["bash", "-uc"]

project := "fwrule"
version := "1.0.0"
src     := "src/"
bin     := "bin/" + project

default:
    @just --list --unsorted

[group('build')]
build:
    v -o {{bin}} {{src}}

[group('build')]
release:
    v -prod -o {{bin}} {{src}}
    @ls -lh {{bin}}

[group('test')]
test:
    v test {{src}}

[group('test')]
test-verbose:
    v -stats test {{src}}

[group('dev')]
fmt:
    v fmt -w {{src}}

[group('dev')]
fmt-check:
    v fmt -verify {{src}}

[group('dev')]
run *ARGS:
    v -o {{bin}} {{src}} && ./{{bin}} {{ARGS}}

[group('dev')]
load FILE:
    @just run load {{FILE}}

[group('dev')]
analyze FILE:
    @just run analyze {{FILE}}

[group('dev')]
harden *ARGS:
    @just run harden {{ARGS}}

[group('dev')]
export FILE *ARGS:
    @just run export {{FILE}} {{ARGS}}

[group('dev')]
diff F1 F2:
    @just run diff {{F1}} {{F2}}

[group('util')]
clean:
    rm -rf bin/
    find . -name '*.tmp.c' -delete

[group('util')]
info:
    @echo "{{project}} v{{version}}"
    @echo "V compiler: $(v version)"
    @echo "Platform:   $(uname -s)/$(uname -m)"

[group('util')]
smoke: build
    ./{{bin}} version
    ./{{bin}} help
    ./{{bin}} load testdata/iptables_basic.rules
    ./{{bin}} load testdata/nftables_basic.rules
    ./{{bin}} analyze testdata/iptables_conflicts.rules
    ./{{bin}} harden -s ssh,http,https -f iptables
    ./{{bin}} harden -s ssh,http,https -f nftables
    ./{{bin}} export testdata/iptables_basic.rules -f nftables
    ./{{bin}} diff testdata/iptables_basic.rules testdata/nftables_basic.rules
    @echo "All smoke tests passed"
