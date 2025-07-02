;; Dispute Resolution Contract
;; Handles invoice disputes and arbitration

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u500))
(define-constant ERR_DISPUTE_NOT_FOUND (err u501))
(define-constant ERR_INVALID_STATUS (err u502))
(define-constant ERR_ALREADY_RESOLVED (err u503))
(define-constant ERR_INVALID_EVIDENCE (err u504))
(define-constant ERR_ARBITRATOR_NOT_ASSIGNED (err u505))

;; Data Variables
(define-data-var next-dispute-id uint u1)
(define-data-var contract-active bool true)

;; Data Maps
(define-map disputes
  uint
  {
    invoice-id: uint,
    complainant: principal,
    respondent: principal,
    dispute-type: (string-ascii 50),
    description: (string-ascii 500),
    amount-disputed: uint,
    status: (string-ascii 20),
    created-at: uint,
    resolved-at: uint,
    resolution: (string-ascii 500)
  }
)

(define-map dispute-evidence
  { dispute-id: uint, evidence-id: uint }
  {
    submitter: principal,
    evidence-type: (string-ascii 30),
    evidence-hash: (string-ascii 64),
    description: (string-ascii 200),
    submitted-at: uint,
    verified: bool
  }
)

(define-map arbitrators
  principal
  {
    registered: bool,
    specialization: (string-ascii 100),
    cases-handled: uint,
    success-rate: uint,
    available: bool
  }
)

(define-map dispute-assignments
  uint
  {
    arbitrator: principal,
    assigned-at: uint,
    accepted: bool,
    deadline: uint
  }
)

(define-map arbitration-decisions
  uint
  {
    arbitrator: principal,
    decision: (string-ascii 20),
    reasoning: (string-ascii 500),
    awarded-amount: uint,
    awarded-to: principal,
    decided-at: uint
  }
)

;; Public Functions

;; Register arbitrator
(define-public (register-arbitrator (arbitrator principal) (specialization (string-ascii 100)))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (var-get contract-active) ERR_UNAUTHORIZED)

    (map-set arbitrators arbitrator {
      registered: true,
      specialization: specialization,
      cases-handled: u0,
      success-rate: u100,
      available: true
    })

    (ok true)
  )
)

;; Create dispute
(define-public (create-dispute
  (invoice-id uint)
  (respondent principal)
  (dispute-type (string-ascii 50))
  (description (string-ascii 500))
  (amount-disputed uint))
  (let ((dispute-id (var-get next-dispute-id)))
    (begin
      (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
      (asserts! (> amount-disputed u0) ERR_INVALID_EVIDENCE)

      (map-set disputes dispute-id {
        invoice-id: invoice-id,
        complainant: tx-sender,
        respondent: respondent,
        dispute-type: dispute-type,
        description: description,
        amount-disputed: amount-disputed,
        status: "open",
        created-at: block-height,
        resolved-at: u0,
        resolution: ""
      })

      (var-set next-dispute-id (+ dispute-id u1))
      (ok dispute-id)
    )
  )
)

;; Submit evidence
(define-public (submit-evidence
  (dispute-id uint)
  (evidence-id uint)
  (evidence-type (string-ascii 30))
  (evidence-hash (string-ascii 64))
  (description (string-ascii 200)))
  (let ((dispute-data (unwrap! (map-get? disputes dispute-id) ERR_DISPUTE_NOT_FOUND)))
    (begin
      (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
      (asserts! (or (is-eq tx-sender (get complainant dispute-data))
                    (is-eq tx-sender (get respondent dispute-data))) ERR_UNAUTHORIZED)
      (asserts! (is-eq (get status dispute-data) "open") ERR_ALREADY_RESOLVED)

      (map-set dispute-evidence { dispute-id: dispute-id, evidence-id: evidence-id } {
        submitter: tx-sender,
        evidence-type: evidence-type,
        evidence-hash: evidence-hash,
        description: description,
        submitted-at: block-height,
        verified: false
      })

      (ok true)
    )
  )
)

;; Assign arbitrator to dispute
(define-public (assign-arbitrator (dispute-id uint) (arbitrator principal))
  (let ((dispute-data (unwrap! (map-get? disputes dispute-id) ERR_DISPUTE_NOT_FOUND))
        (arbitrator-data (unwrap! (map-get? arbitrators arbitrator) ERR_UNAUTHORIZED)))
    (begin
      (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
      (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
      (asserts! (get registered arbitrator-data) ERR_UNAUTHORIZED)
      (asserts! (get available arbitrator-data) ERR_UNAUTHORIZED)
      (asserts! (is-eq (get status dispute-data) "open") ERR_ALREADY_RESOLVED)

      (map-set dispute-assignments dispute-id {
        arbitrator: arbitrator,
        assigned-at: block-height,
        accepted: false,
        deadline: (+ block-height u1008) ;; ~7 days
      })

      ;; Update dispute status
      (map-set disputes dispute-id
        (merge dispute-data { status: "assigned" }))

      ;; Mark arbitrator as unavailable
      (map-set arbitrators arbitrator
        (merge arbitrator-data { available: false }))

      (ok true)
    )
  )
)

;; Accept arbitration assignment
(define-public (accept-arbitration (dispute-id uint))
  (let ((assignment (unwrap! (map-get? dispute-assignments dispute-id) ERR_ARBITRATOR_NOT_ASSIGNED))
        (dispute-data (unwrap! (map-get? disputes dispute-id) ERR_DISPUTE_NOT_FOUND)))
    (begin
      (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
      (asserts! (is-eq tx-sender (get arbitrator assignment)) ERR_UNAUTHORIZED)
      (asserts! (not (get accepted assignment)) ERR_INVALID_STATUS)

      (map-set dispute-assignments dispute-id
        (merge assignment { accepted: true }))

      ;; Update dispute status
      (map-set disputes dispute-id
        (merge dispute-data { status: "in-arbitration" }))

      (ok true)
    )
  )
)

;; Submit arbitration decision
(define-public (submit-decision
  (dispute-id uint)
  (decision (string-ascii 20))
  (reasoning (string-ascii 500))
  (awarded-amount uint)
  (awarded-to principal))
  (let ((assignment (unwrap! (map-get? dispute-assignments dispute-id) ERR_ARBITRATOR_NOT_ASSIGNED))
        (dispute-data (unwrap! (map-get? disputes dispute-id) ERR_DISPUTE_NOT_FOUND)))
    (begin
      (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
      (asserts! (is-eq tx-sender (get arbitrator assignment)) ERR_UNAUTHORIZED)
      (asserts! (get accepted assignment) ERR_UNAUTHORIZED)
      (asserts! (is-eq (get status dispute-data) "in-arbitration") ERR_ALREADY_RESOLVED)

      (map-set arbitration-decisions dispute-id {
        arbitrator: tx-sender,
        decision: decision,
        reasoning: reasoning,
        awarded-amount: awarded-amount,
        awarded-to: awarded-to,
        decided-at: block-height
      })

      ;; Update dispute status
      (map-set disputes dispute-id
        (merge dispute-data {
          status: "resolved",
          resolved-at: block-height,
          resolution: reasoning
        }))

      ;; Update arbitrator stats
      (let ((arbitrator-data (unwrap-panic (map-get? arbitrators tx-sender))))
        (map-set arbitrators tx-sender
          (merge arbitrator-data {
            cases-handled: (+ (get cases-handled arbitrator-data) u1),
            available: true
          }))
      )

      (ok true)
    )
  )
)

;; Appeal decision
(define-public (appeal-decision (dispute-id uint) (appeal-reason (string-ascii 500)))
  (let ((dispute-data (unwrap! (map-get? disputes dispute-id) ERR_DISPUTE_NOT_FOUND)))
    (begin
      (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
      (asserts! (or (is-eq tx-sender (get complainant dispute-data))
                    (is-eq tx-sender (get respondent dispute-data))) ERR_UNAUTHORIZED)
      (asserts! (is-eq (get status dispute-data) "resolved") ERR_INVALID_STATUS)

      ;; Update dispute status for appeal
      (map-set disputes dispute-id
        (merge dispute-data {
          status: "appealed",
          resolution: appeal-reason
        }))

      (ok true)
    )
  )
)

;; Verify evidence
(define-public (verify-evidence (dispute-id uint) (evidence-id uint))
  (let ((assignment (unwrap! (map-get? dispute-assignments dispute-id) ERR_ARBITRATOR_NOT_ASSIGNED))
        (evidence (unwrap! (map-get? dispute-evidence { dispute-id: dispute-id, evidence-id: evidence-id }) ERR_INVALID_EVIDENCE)))
    (begin
      (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
      (asserts! (is-eq tx-sender (get arbitrator assignment)) ERR_UNAUTHORIZED)

      (map-set dispute-evidence { dispute-id: dispute-id, evidence-id: evidence-id }
        (merge evidence { verified: true }))

      (ok true)
    )
  )
)

;; Read-only Functions

;; Get dispute details
(define-read-only (get-dispute (dispute-id uint))
  (map-get? disputes dispute-id)
)

;; Get evidence
(define-read-only (get-evidence (dispute-id uint) (evidence-id uint))
  (map-get? dispute-evidence { dispute-id: dispute-id, evidence-id: evidence-id })
)

;; Get arbitrator info
(define-read-only (get-arbitrator-info (arbitrator principal))
  (map-get? arbitrators arbitrator)
)

;; Get dispute assignment
(define-read-only (get-dispute-assignment (dispute-id uint))
  (map-get? dispute-assignments dispute-id)
)

;; Get arbitration decision
(define-read-only (get-arbitration-decision (dispute-id uint))
  (map-get? arbitration-decisions dispute-id)
)

;; Check if dispute is resolved
(define-read-only (is-dispute-resolved (dispute-id uint))
  (match (map-get? disputes dispute-id)
    dispute (is-eq (get status dispute) "resolved")
    false
  )
)

;; Get available arbitrators (simplified)
(define-read-only (is-arbitrator-available (arbitrator principal))
  (match (map-get? arbitrators arbitrator)
    arb-data (and (get registered arb-data) (get available arb-data))
    false
  )
)
