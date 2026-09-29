# Citation and prior-art check — 2026-09-23

Everything below was opened today. Each entry records the claim the proposal makes, what the source
actually says, and the exact wording relied on. Anything not opened today is marked as such.

## 1. Token Budgets — arXiv 2606.04056

- Title: *Token Budgets: An Empirical Catalog of 63 LLM-Agent Budget-Overrun Incidents, with an
  Affine-Typed Rust Mitigation as a Case Study*. Single author: Sajjad Khan (independent researcher).
  cs.SE, submitted 2 June 2026, 26 pages. https://arxiv.org/abs/2606.04056
- Verified wording (abstract): "a catalog of 63 confirmed production incidents from 21 orchestration
  frameworks".
- Supports: budget overrun in delegated autonomous execution is a documented production failure class,
  and the mitigation shipped with the paper is an off-chain Rust type system, not on-chain enforcement.
- **Two corrections to v1.3.** The catalog is June 2026, not August 2026. The incidents come from LLM
  orchestration frameworks (API/token spend), not from on-chain payments, so the proposal must not imply
  on-chain incidents. v1.4 drops the sentence rather than qualify it in a one-page document.

## 2. AIP — arXiv 2603.24775

- Title: *AIP: Agent Identity Protocol for Verifiable Delegation Across MCP and A2A*. Sunil Prakash
  (Indian School of Business). cs.CR, submitted 25 March 2026. https://arxiv.org/abs/2603.24775
  Also published as IETF Internet-Draft draft-prakash-aip-00.
- Verified wording, §3.4 Budget Semantics: "Aggregate spend enforcement is the runtime's responsibility,
  not the token's". The same section states that budget fields are per-token authorization ceilings, not
  running balances, and that the verifier does not track cumulative spend.
- Supports: the related-work row saying AIP leaves aggregate enforcement outside the token layer.
  This is the strongest external statement in the proposal that the gap is real and acknowledged.

## 3. CapLease — arXiv 2608.01710

- Title: *Beyond Single-Use Tokens: Durable Authorization State for Replay-Resistant LLM Agent Actions*.
  Jinghan Xu, Longze Fan, Zeyuan Wang, Xinjin Li, Hankai Liu. cs.AI, submitted 3 August 2026.
  https://arxiv.org/abs/2608.01710
- Verified wording (abstract): semantic replay is defined as "exceeding the execution budget of a
  token-independent authorization instance".
- Supports: durable budget state per authorization instance, enforced off-chain.
- **Correction to v1.3.** v1.3 described the ledger as an "off-chain SQL ledger". The abstract and the
  protocol figure say durable authorization ledger with Issue–Prepare–Commit transitions; the SQL detail
  was not confirmed today, so v1.4 says off-chain only.

## 4. Kamoun & Kleinrock 1980

- F. Kamoun and L. Kleinrock, "Analysis of Shared Finite Storage in a Computer Network Node Environment
  Under General Traffic Conditions", *IEEE Transactions on Communications*, vol. COM-28, no. 7,
  pp. 992–1003, July 1980. DOI 10.1109/TCOM.1980.1094756
- Status: metadata confirmed consistently across several independent citing works. **The full text was
  not accessed** (IEEE paywall), so no quotation from it is used anywhere.
- The policy names the design descends from are taken from a source that was read: I. Cidon,
  L. Georgiadis, R. Guérin, A. Khamisy, "Optimal Buffer Sharing", *IEEE JSAC*, vol. 13, no. 7,
  pp. 1229–1240, September 1995, whose introduction defines complete sharing, complete partitioning, and
  sharing with a minimum allocation, in which a minimum number of buffers is reserved per port and the
  rest is shared. v1.4 therefore names the family without attributing a specific formulation to the 1980
  paper.

## 5. ERC-7579 SpendingLimitHook — source read

- `rhinestonewtf/experimental-modules`, file `src/SpendingLimitHook/SpendingLimitHook.sol`, main branch,
  read 2026-09-23. https://github.com/rhinestonewtf/experimental-modules
- What the code does: state is `mapping(address account => mapping(address token => SpendingLimit))`,
  where `SpendingLimit` is `{ uint256 limit; mapping(uint256 timeperiod => uint256) spent; }`. The period
  is `block.timestamp / 1 weeks`, hard-coded. The check fires only when the call data selector equals
  `IERC20.transfer`, and reverts when `spent[timeperiod] + value > limit`.
- Consequences for the proposal: the counter is account-wide per token. It carries no delegate, session
  or key dimension, so it is the rho = 0 endpoint with a fixed one-week window, and it provides no
  isolation between spenders by construction. Coverage is also narrower than v1.3 implied: native value
  and `transferFrom` are not counted.
- v1.3's row said "source not reviewed". That row is now replaced by the description above.

## 6. ERC-7579 SmartSessions — source read

- `rhinestonewtf/smartsessions`, `contracts/external/policies/`, main branch, read 2026-09-23.
  Policies present: ERC20SpendingLimitPolicy, ValueLimitPolicy, UsageLimitPolicy, TimeFramePolicy,
  SudoPolicy, ContractWhitelistPolicy, ArgPolicy, SimpleGasPolicy, UniActionPolicy.
- `ERC20SpendingLimitPolicy.sol` keys its state by `ConfigId id` (the session), then multiplexer, token,
  and `userOpSender`; it holds `spendingLimit`, `alreadySpent` and `approvedAmount`, and reverts when
  `alreadySpent + approvedAmount > spendingLimit`.
- Consequence: the limit is per session. Two sessions under the same account keep independent counters,
  which is the per-delegate endpoint of the design space.

## 7. Not re-verified today

- The 28 MetaMask Delegation Toolkit caveat enforcers were checked on 2026-08-08 against the official
  documentation, including the period-transfer hard reset at each period boundary. Not re-opened today;
  if the proposal is challenged on that row, re-check before answering.
- Whether any production wallet or merged standard now implements a principal-level shared budget with
  cross-delegate reservations — the one PIVOT condition — was not re-run as a full sweep. The three
  sources read today are all consistent with the September 2026 wording used in the proposal.
