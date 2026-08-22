# go-blocks

An opinionated Go ecosystem for building compliance-ready enterprise backends on
[go-kratos](https://github.com/go-kratos/kratos) v3 — inspired by Elixir's
[Ash Framework](https://ash-hq.org/) philosophy of "model your domain, derive the rest".

Goals: standardized engineering practice, reusable modular blocks, predictable
behaviour, contract-driven development on protobuf, a cost-driven modular monolith with
local-first data, compliance by construction (ISO/IEC 27001, GDPR, Indonesian PDP Law
UU 27/2022), and a system that coding agents and runtime LLM agents can read and drive.

First product driving the design: an F&B mini-ERP — full operational ERP scope minus the
accounting ledger, which is delegated to [Accurate Online](https://accurate.id/).

## Status

Design phase. No framework code yet. The architecture analysis lives in
[`docs/approaches/`](docs/approaches/README.md) — five candidate approaches with
tradeoffs, effort estimates, and a comparative analysis.

Start here: **[docs/approaches/README.md](docs/approaches/README.md)**
