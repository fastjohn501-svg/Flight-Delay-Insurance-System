;; instant-payout-system
;; Automated instant payouts based on verified flight delay triggers

;; constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u3001))
(define-constant ERR_POLICY_NOT_FOUND (err u3002))
(define-constant ERR_INVALID_POLICY_DATA (err u3003))
(define-constant ERR_INSUFFICIENT_FUNDS (err u3004))
(define-constant ERR_POLICY_EXPIRED (err u3005))
(define-constant ERR_CLAIM_ALREADY_PROCESSED (err u3006))
(define-constant ERR_DELAY_NOT_QUALIFYING (err u3007))

;; Policy status codes
(define-constant POLICY_ACTIVE u0)
(define-constant POLICY_CLAIMED u1)
(define-constant POLICY_EXPIRED u2)
(define-constant POLICY_CANCELLED u3)

;; Payout tier thresholds
(define-constant TIER_1_MIN_DELAY u30)
(define-constant TIER_2_MIN_DELAY u60)
(define-constant TIER_3_MIN_DELAY u120)
(define-constant TIER_4_MIN_DELAY u240)

;; data maps and vars
(define-map insurance-policies
  { policy-id: uint }
  {
    policyholder: principal,
    flight-id: (string-ascii 20),
    premium-paid: uint,
    coverage-amount: uint,
    policy-start: uint,
    policy-end: uint,
    min-delay-threshold: uint,
    status: uint,
    created-block: uint
  }
)

(define-map policy-claims
  { claim-id: uint }
  {
    policy-id: uint,
    flight-id: (string-ascii 20),
    delay-minutes: uint,
    payout-amount: uint,
    claim-timestamp: uint,
    processor: principal
  }
)

(define-data-var next-policy-id uint u1)
(define-data-var next-claim-id uint u1)
(define-data-var contract-paused bool false)
(define-data-var total-policies-issued uint u0)

;; private functions
(define-private (min-uint (a uint) (b uint))
  (if (<= a b) a b))

(define-private (is-policy-valid (policy-id uint))
  (match (map-get? insurance-policies { policy-id: policy-id })
    policy-data (and
                  (is-eq (get status policy-data) POLICY_ACTIVE)
                  (>= stacks-block-height (get policy-start policy-data))
                  (<= stacks-block-height (get policy-end policy-data)))
    false))

(define-private (get-tier-percentage (delay-minutes uint))
  (if (>= delay-minutes TIER_4_MIN_DELAY)
    u100
    (if (>= delay-minutes TIER_3_MIN_DELAY)
      u75
      (if (>= delay-minutes TIER_2_MIN_DELAY)
        u50
        (if (>= delay-minutes TIER_1_MIN_DELAY)
          u25
          u0)))))

(define-private (calculate-payout-amount (policy-id uint) (delay-minutes uint))
  (match (map-get? insurance-policies { policy-id: policy-id })
    policy-data
    (let (
      (base-coverage (get coverage-amount policy-data))
      (tier-percentage (get-tier-percentage delay-minutes))
      (payout (/ (* base-coverage tier-percentage) u100))
    )
      (min-uint base-coverage payout))
    u0))

(define-private (is-delay-qualifying (policy-id uint) (delay-minutes uint))
  (match (map-get? insurance-policies { policy-id: policy-id })
    policy-data (>= delay-minutes (get min-delay-threshold policy-data))
    false))

;; public functions
(define-public (create-insurance-policy
  (flight-id (string-ascii 20))
  (coverage-amount uint)
  (policy-duration-blocks uint)
  (min-delay-threshold uint))
  (let (
    (policy-id (var-get next-policy-id))
    (premium (/ coverage-amount u20))
    (policy-start stacks-block-height)
    (policy-end (+ stacks-block-height policy-duration-blocks))
  )
    (asserts! (not (var-get contract-paused)) ERR_NOT_AUTHORIZED)
    (asserts! (> coverage-amount u0) ERR_INVALID_POLICY_DATA)
    (asserts! (>= min-delay-threshold u15) ERR_INVALID_POLICY_DATA)
    (asserts! (> policy-duration-blocks u0) ERR_INVALID_POLICY_DATA)
    (asserts! (>= (stx-get-balance tx-sender) premium) ERR_INSUFFICIENT_FUNDS)
    (try! (stx-transfer? premium tx-sender (as-contract tx-sender)))
    (map-set insurance-policies
      { policy-id: policy-id }
      {
        policyholder: tx-sender,
        flight-id: flight-id,
        premium-paid: premium,
        coverage-amount: coverage-amount,
        policy-start: policy-start,
        policy-end: policy-end,
        min-delay-threshold: min-delay-threshold,
        status: POLICY_ACTIVE,
        created-block: stacks-block-height
      })
    (var-set next-policy-id (+ policy-id u1))
    (var-set total-policies-issued (+ (var-get total-policies-issued) u1))
    (print {
      event: "policy-created",
      policy-id: policy-id,
      policyholder: tx-sender,
      flight-id: flight-id,
      premium: premium,
      coverage: coverage-amount
    })
    (ok policy-id)))

(define-public (trigger-automatic-payout
  (policy-id uint)
  (delay-minutes uint))
  (let (
    (policy-data (unwrap! (map-get? insurance-policies { policy-id: policy-id }) ERR_POLICY_NOT_FOUND))
    (payout-amount (calculate-payout-amount policy-id delay-minutes))
    (claim-id (var-get next-claim-id))
  )
    (asserts! (not (var-get contract-paused)) ERR_NOT_AUTHORIZED)
    (asserts! (is-policy-valid policy-id) ERR_POLICY_EXPIRED)
    (asserts! (is-delay-qualifying policy-id delay-minutes) ERR_DELAY_NOT_QUALIFYING)
    (asserts! (not (is-eq (get status policy-data) POLICY_CLAIMED)) ERR_CLAIM_ALREADY_PROCESSED)
    (asserts! (> payout-amount u0) ERR_DELAY_NOT_QUALIFYING)
    (map-set policy-claims
      { claim-id: claim-id }
      {
        policy-id: policy-id,
        flight-id: (get flight-id policy-data),
        delay-minutes: delay-minutes,
        payout-amount: payout-amount,
        claim-timestamp: stacks-block-height,
        processor: tx-sender
      })
    (map-set insurance-policies
      { policy-id: policy-id }
      (merge policy-data { status: POLICY_CLAIMED }))
    (var-set next-claim-id (+ claim-id u1))
    (try! (as-contract (stx-transfer? payout-amount tx-sender (get policyholder policy-data))))
    (print {
      event: "automatic-payout-processed",
      policy-id: policy-id,
      claim-id: claim-id,
      payout-amount: payout-amount
    })
    (ok payout-amount)))

(define-public (emergency-pause)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (var-set contract-paused true)
    (print { event: "payout-system-paused" })
    (ok true)))

(define-public (emergency-unpause)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (var-set contract-paused false)
    (print { event: "payout-system-unpaused" })
    (ok true)))

;; Read-only functions
(define-read-only (get-policy-data (policy-id uint))
  (map-get? insurance-policies { policy-id: policy-id }))

(define-read-only (get-claim-data (claim-id uint))
  (map-get? policy-claims { claim-id: claim-id }))

(define-read-only (get-payout-estimate (policy-id uint) (delay-minutes uint))
  (let (
    (payout-amount (calculate-payout-amount policy-id delay-minutes))
    (tier-percentage (get-tier-percentage delay-minutes))
  )
    {
      estimated-payout: payout-amount,
      tier-percentage: tier-percentage,
      qualifies: (is-delay-qualifying policy-id delay-minutes)
    }))

(define-read-only (get-contract-stats)
  {
    total-policies: (var-get total-policies-issued),
    next-policy-id: (var-get next-policy-id),
    is-paused: (var-get contract-paused),
    contract-balance: (stx-get-balance (as-contract tx-sender))
  })

(define-read-only (is-policy-active (policy-id uint))
  (is-policy-valid policy-id))