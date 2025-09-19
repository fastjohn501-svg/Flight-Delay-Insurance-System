;; flight-data-oracle
;; Integration with flight tracking APIs for real-time delay and cancellation data

;; constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u1001))
(define-constant ERR_FLIGHT_NOT_FOUND (err u1002))
(define-constant ERR_INVALID_FLIGHT_DATA (err u1003))
(define-constant ERR_ALREADY_REPORTED (err u1004))
(define-constant ERR_INVALID_TIMESTAMP (err u1005))
(define-constant ERR_ORACLE_NOT_REGISTERED (err u1006))
(define-constant ERR_INSUFFICIENT_CONFIRMATIONS (err u1007))

;; Flight status codes
(define-constant STATUS_SCHEDULED u0)
(define-constant STATUS_DELAYED u1)
(define-constant STATUS_CANCELLED u2)
(define-constant STATUS_BOARDING u3)
(define-constant STATUS_DEPARTED u4)
(define-constant STATUS_ARRIVED u5)

;; data maps and vars
(define-map flights
  { flight-id: (string-ascii 20) }
  {
    airline: (string-ascii 10),
    flight-number: (string-ascii 10),
    departure-airport: (string-ascii 5),
    arrival-airport: (string-ascii 5),
    scheduled-departure: uint,
    scheduled-arrival: uint,
    actual-departure: (optional uint),
    actual-arrival: (optional uint),
    status: uint,
    delay-minutes: uint,
    last-updated: uint,
    confirmations: uint,
    is-active: bool
  }
)

(define-map flight-updates
  { flight-id: (string-ascii 20), update-id: uint }
  {
    reporter: principal,
    timestamp: uint,
    status: uint,
    delay-minutes: uint,
stacks-stacks-block-height
  }
)

(define-map authorized-oracles
  { oracle: principal }
  {
    is-authorized: bool,
    reputation-score: uint,
    total-reports: uint,
    successful-reports: uint,
    registration-block: uint
  }
)

(define-map flight-subscribers
  { flight-id: (string-ascii 20), subscriber: principal }
  { notification-threshold: uint, is-active: bool }
)

(define-data-var next-update-id uint u0)
(define-data-var min-confirmations uint u3)
(define-data-var oracle-count uint u0)
(define-data-var contract-paused bool false)

;; private functions
(define-private (min-uint (a uint) (b uint))
  (if (<= a b) a b))

(define-private (is-authorized-oracle (oracle principal))
  (default-to false
    (get is-authorized (map-get? authorized-oracles { oracle: oracle }))))

(define-private (is-valid-status (status uint))
  (and (>= status STATUS_SCHEDULED) (<= status STATUS_ARRIVED)))

(define-private (is-valid-timestamp (timestamp uint))
  (> timestamp u0)) ;; Simplified timestamp validation

(define-private (calculate-delay-minutes (scheduled uint) (actual uint))
  (if (> actual scheduled)
    (/ (- actual scheduled) u60) ;; Convert seconds to minutes
    u0))

(define-private (update-oracle-reputation (oracle principal) (successful bool))
  (let (
    (oracle-data (unwrap! (map-get? authorized-oracles { oracle: oracle }) false))
    (new-total (+ (get total-reports oracle-data) u1))
    (new-successful (if successful 
                     (+ (get successful-reports oracle-data) u1)
                     (get successful-reports oracle-data)))
    (new-score (if (> new-total u0)
                (/ (* new-successful u100) new-total)
                u0))
  )
    (map-set authorized-oracles
      { oracle: oracle }
      (merge oracle-data {
        total-reports: new-total,
        successful-reports: new-successful,
        reputation-score: new-score
      }))))

(define-private (emit-flight-update-event (flight-id (string-ascii 20)) (status uint) (delay uint))
  (print {
    event: "flight-update",
    flight-id: flight-id,
    status: status,
    delay-minutes: delay,
    timestamp: stacks-block-height
  }))

(define-private (validate-flight-data 
  (airline (string-ascii 10))
  (flight-number (string-ascii 10))
  (departure-airport (string-ascii 5))
  (arrival-airport (string-ascii 5))
  (scheduled-departure uint)
  (scheduled-arrival uint))
  (and
    (> (len airline) u0)
    (> (len flight-number) u0)
    (> (len departure-airport) u2)
    (> (len arrival-airport) u2)
    (> scheduled-departure u0)
    (> scheduled-arrival scheduled-departure)
    (not (is-eq departure-airport arrival-airport))))

;; public functions
(define-public (register-oracle (oracle principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (asserts! (not (var-get contract-paused)) ERR_NOT_AUTHORIZED)
    (map-set authorized-oracles
      { oracle: oracle }
      {
        is-authorized: true,
        reputation-score: u100,
        total-reports: u0,
        successful-reports: u0,
        registration-block: stacks-block-height
      })
    (var-set oracle-count (+ (var-get oracle-count) u1))
    (print { event: "oracle-registered", oracle: oracle })
    (ok true)))

(define-public (revoke-oracle (oracle principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (asserts! (is-authorized-oracle oracle) ERR_ORACLE_NOT_REGISTERED)
    (map-set authorized-oracles
      { oracle: oracle }
      { is-authorized: false,
        reputation-score: u0,
        total-reports: u0,
        successful-reports: u0,
        registration-block: u0 })
    (var-set oracle-count (- (var-get oracle-count) u1))
    (print { event: "oracle-revoked", oracle: oracle })
    (ok true)))

(define-public (register-flight
  (flight-id (string-ascii 20))
  (airline (string-ascii 10))
  (flight-number (string-ascii 10))
  (departure-airport (string-ascii 5))
  (arrival-airport (string-ascii 5))
  (scheduled-departure uint)
  (scheduled-arrival uint))
  (begin
    (asserts! (not (var-get contract-paused)) ERR_NOT_AUTHORIZED)
    (asserts! (is-none (map-get? flights { flight-id: flight-id })) ERR_ALREADY_REPORTED)
    (asserts! (validate-flight-data airline flight-number departure-airport arrival-airport scheduled-departure scheduled-arrival) ERR_INVALID_FLIGHT_DATA)
    (map-set flights
      { flight-id: flight-id }
      {
        airline: airline,
        flight-number: flight-number,
        departure-airport: departure-airport,
        arrival-airport: arrival-airport,
        scheduled-departure: scheduled-departure,
        scheduled-arrival: scheduled-arrival,
        actual-departure: none,
        actual-arrival: none,
        status: STATUS_SCHEDULED,
        delay-minutes: u0,
        last-updated: stacks-block-height,
        confirmations: u1,
        is-active: true
      })
    (print {
      event: "flight-registered",
      flight-id: flight-id,
      airline: airline,
      flight-number: flight-number
    })
    (ok true)))

(define-public (update-flight-status
  (flight-id (string-ascii 20))
  (new-status uint)
  (actual-departure (optional uint))
  (actual-arrival (optional uint)))
  (let (
    (flight-data (unwrap! (map-get? flights { flight-id: flight-id }) ERR_FLIGHT_NOT_FOUND))
    (update-id (var-get next-update-id))
    (delay-minutes (if (and (is-some actual-departure) (> (unwrap-panic actual-departure) (get scheduled-departure flight-data)))
                    (calculate-delay-minutes (get scheduled-departure flight-data) (unwrap-panic actual-departure))
                    u0))
  )
    (asserts! (not (var-get contract-paused)) ERR_NOT_AUTHORIZED)
    (asserts! (is-authorized-oracle tx-sender) ERR_ORACLE_NOT_REGISTERED)
    (asserts! (get is-active flight-data) ERR_INVALID_FLIGHT_DATA)
    (asserts! (is-valid-status new-status) ERR_INVALID_FLIGHT_DATA)
    (map-set flight-updates
      { flight-id: flight-id, update-id: update-id }
      {
        reporter: tx-sender,
        timestamp: stacks-block-height,
        status: new-status,
        delay-minutes: delay-minutes,
        stacks-block-height: stacks-block-height
      })
    (var-set next-update-id (+ update-id u1))
    (if (>= (+ (get confirmations flight-data) u1) (var-get min-confirmations))
      (begin
        (map-set flights
          { flight-id: flight-id }
          (merge flight-data {
            status: new-status,
            actual-departure: actual-departure,
            actual-arrival: actual-arrival,
            delay-minutes: delay-minutes,
            last-updated: stacks-block-height,
            confirmations: (+ (get confirmations flight-data) u1)
          }))
        (update-oracle-reputation tx-sender true)
        (emit-flight-update-event flight-id new-status delay-minutes)
        (ok { confirmed: true, delay-minutes: delay-minutes }))
      (begin
        (map-set flights
          { flight-id: flight-id }
          (merge flight-data {
            confirmations: (+ (get confirmations flight-data) u1)
          }))
        (ok { confirmed: false, delay-minutes: delay-minutes })))))

(define-public (subscribe-to-flight (flight-id (string-ascii 20)) (threshold uint))
  (begin
    (asserts! (not (var-get contract-paused)) ERR_NOT_AUTHORIZED)
    (asserts! (is-some (map-get? flights { flight-id: flight-id })) ERR_FLIGHT_NOT_FOUND)
    (map-set flight-subscribers
      { flight-id: flight-id, subscriber: tx-sender }
      { notification-threshold: threshold, is-active: true })
    (print {
      event: "flight-subscription",
      subscriber: tx-sender,
      flight-id: flight-id,
      threshold: threshold
    })
    (ok true)))

(define-public (emergency-pause)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (var-set contract-paused true)
    (print { event: "contract-paused" })
    (ok true)))

(define-public (emergency-unpause)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (var-set contract-paused false)
    (print { event: "contract-unpaused" })
    (ok true)))

;; Read-only functions
(define-read-only (get-flight-data (flight-id (string-ascii 20)))
  (map-get? flights { flight-id: flight-id }))

(define-read-only (get-oracle-info (oracle principal))
  (map-get? authorized-oracles { oracle: oracle }))

(define-read-only (get-flight-update (flight-id (string-ascii 20)) (update-id uint))
  (map-get? flight-updates { flight-id: flight-id, update-id: update-id }))

(define-read-only (is-flight-delayed (flight-id (string-ascii 20)) (threshold uint))
  (match (map-get? flights { flight-id: flight-id })
    flight-data (ok (>= (get delay-minutes flight-data) threshold))
    ERR_FLIGHT_NOT_FOUND))

(define-read-only (get-contract-info)
  {
    oracle-count: (var-get oracle-count),
    min-confirmations: (var-get min-confirmations),
    is-paused: (var-get contract-paused),
    next-update-id: (var-get next-update-id)
  })
