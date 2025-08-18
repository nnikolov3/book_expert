# DESIGN_PRINCIPLES_GUIDE.md

## Purpose

This guide defines foundational design principles for coding, system design, and algorithms. These principles are to be strictly followed across all projects to ensure clarity, robustness, maintainability, and professional quality. They are intentionally concise, explicit, and practical.

## Core Principles

- Do more with less.
- Keep it simple.
- Prefer readability and clarity over performance.
- Make it explicit.
- Fast is slow; no cutting corners.
- Regularity favors consistency.
- Principle of least astonishment.
- Code follows modern self-documenting principles.
- Do not make it complex if it does not need to be.
- Simplicity favors regularity.
- Smaller is faster.
- Make the common case fast.
- Good design demands good compromises.
- Abstraction and modularity.
- Consistency over cleverness.
- Don’t fix what ain’t broken.
- Understand the objective.
- Test, confirm, validate, lint, analyze, refactor, and improve, repeat.
- Never hardcode values or use magic numbers.
- Instantiate variables at the top of their respective code block.
- Code blocks should be clear, with discrete intent, limited responsibility, and semantically aligned.
- Consult the specifications, documentation, and manuals; do not assume.
- If it ain’t used, it gets removed.
- If too many conditionals are needed, check the logic.
- Determine and outline the problem; investigate.
- Break the problem down to its smallest possible elements.
- Divide work into the smallest possible tasks; after completing each task, test the work.
- Always look for ways to clean, organize, simplify, optimize, detect issues, and improve.
- Use modern Test Driven Development.
- Follow best practices as documented in official specifications for Go, Rust, C, C++, Python, and others.
- Every line of code should have a reason to be there.
- To win we need to be a team.

## Clarifications and Operationalization

### 0) Pre-Code Validation

- Before writing any code, confirm the code is actually needed and not a duplicate of existing functionality.
- Search the codebase and shared libraries first; prefer reuse or extension over reimplementation.
- If new code is justified, document why existing solutions are insufficient and how duplication is avoided.

### 1) Simplicity and Clarity

- Strive for the simplest solution that meets requirements.
- Choose clear names and straightforward control flow over clever constructs.
- Avoid premature optimization; optimize only after measurement.

### 2) Explicitness

- Make assumptions visible and auditable in code, configuration, and documentation.
- Prefer explicit data types, explicit dependencies, and explicit interfaces.
- Avoid hidden side effects and ambiguous behavior.

### 3) Modularity and Abstraction

- Isolate responsibilities into small, composable units.
- Define clear boundaries and interfaces; favor composition over inheritance.
- Hide implementation details behind stable interfaces.

### 4) Correctness and Testing

- Treat tests as first-class citizens; write tests before or alongside code.
- Cover the happy path and edge cases; test for regressions.
- Validate inputs at boundaries; fail fast with actionable diagnostics.

### 5) Maintainability and Readability

- Keep functions short, focused, and intention-revealing.
- Remove dead code and unnecessary abstraction immediately.
- Prefer standard libraries and well-understood patterns over bespoke solutions.

### 6) Performance with Purpose

- Make the common case fast; measure before optimizing.
- Reduce memory allocations and I/O where it matters.
- Document performance expectations and validate them routinely.

### 7) Consistency and Convention

- Follow established style guides and project conventions rigorously.
- Consistent patterns reduce cognitive load and defects.
- Avoid one-off exceptions unless documented and justified.

### 8) Documentation and Self-Documentation

- Write self-documenting code; comments explain “why,” not “what.”
- Keep documentation synchronized with code and architecture.
- Provide runnable examples for critical flows and APIs.

### 9) Security and Safety

- Design for secure defaults and least privilege.
- Validate and sanitize inputs; handle secrets correctly.
- Log security-relevant events with care; never log secrets.

### 10) Continuous Improvement

- Iterate in small steps; test, lint, format, analyze, refactor, and repeat.
- Regularly review design decisions; improve where justified.
- Keep dependencies, tools, and knowledge up to date.

## Process Guidelines

### Problem Understanding

- Clearly define objectives, constraints, limits, and risks.
- Identify missing information and plan how to obtain it.
- Write out the intended logic in plain English before coding.

### Planning and Decomposition

- Break work into minimal, independent, testable tasks.
- Order tasks by dependency and impact; set up a Kanban or TODO board.
- After each task: test, lint, format, refactor, and commit.

### Implementation Discipline

- Declare variables at the top of their block in dependency order.
- Avoid magic numbers; parameterize via configuration.
- Keep code paths simple; if logic needs too many conditionals, revisit design.

### Verification Loop

- Test continuously at unit, integration, and end-to-end levels as needed.
- Validate performance targets on critical paths.
- Run static analysis, linting, and formatting on every change.

### Housekeeping

- Remove unused files, tools, directories, and stale artifacts.
- Keep repository structure organized and documentation current.
- Ensure every line in the codebase has a clear, necessary purpose.

## Practical Checklists

### Design Readiness

- Objective, constraints, and risks are clearly documented.
- Simpler alternatives were considered; chosen design is justified.
- Interfaces and boundaries are explicit and minimal.
- Reuse checked: no duplication created; rationale recorded.

### Code Review Gate

- Readable, minimal, and follows conventions.
- No magic numbers; no dead code; no unnecessary complexity.
- Tests exist and pass; names are intention-revealing; comments explain “why.”
- Confirms no duplication with existing modules, utilities, or services.

### Testing Gate

- Happy paths and edge cases covered.
- Regression tests exist for fixed issues.
- Performance and resource behavior meet expectations.

### Security Gate

- Inputs validated; outputs sanitized where relevant.
- Secrets not logged or exposed; configs parameterized.
- Permissions limited to least privilege; failure modes are safe.

## Example Application Flow

1. Validate necessity: confirm functionality doesn’t already exist; document reuse vs. build decision.
2. Define the objective and constraints in plain language.
3. Identify subproblems; create a dependency-ordered task list.
4. Implement the smallest task first with tests; run lint/format.
5. Refactor for clarity and simplicity; remove any unused elements.
6. Repeat for each task until the objective is met.
7. Validate performance and security; document final design decisions.

## Team Principles

- Communicate with precision and purpose.
- Prefer small, frequent, high-quality changes.
- Share knowledge, review constructively, and maintain collective code ownership.
- Align on the principles above; consistency beats cleverness.

## Closing

These principles are non-negotiable foundations for robust, maintainable, and scalable systems. Apply them rigorously, question complexity, confirm necessity before coding, avoid duplication, and keep improving. Each change should move the system toward simplicity, clarity, and correctness.
