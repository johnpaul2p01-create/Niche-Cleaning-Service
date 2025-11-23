;; Niche Cleaning Service protocol
;; Supports specialized cleaning jobs with escrow and provider liquidity.

(define-constant ERR_JOB_NOT_FOUND u100)
(define-constant ERR_NOT_CUSTOMER u101)
(define-constant ERR_NOT_PROVIDER u102)
(define-constant ERR_INVALID_STATUS u103)
(define-constant ERR_INSUFFICIENT_LIQUIDITY u104)
(define-constant ERR_UNAUTHORIZED u105)
(define-constant ERR_ALREADY_ACCEPTED u106)
(define-constant ERR_NOT_ACCEPTED u107)
(define-constant ERR_ZERO_AMOUNT u108)
(define-constant ERR_INVALID_CATEGORY u109)
(define-constant ERR_WITHDRAW_TOO_MUCH u110)

(define-constant CATEGORY_POST_RENOVATION u1)
(define-constant CATEGORY_BEREAVEMENT u2)
(define-constant CATEGORY_CHILD_GEAR u3)

(define-constant STATUS_OPEN u1)
(define-constant STATUS_ACCEPTED u2)
(define-constant STATUS_COMPLETED u3)
(define-constant STATUS_CANCELLED u4)

;; Tracks the last issued job id
(define-data-var last-job-id uint u0)

;; Job records: escrow is held by the contract in STX; price is in microSTX.
(define-map jobs
  { id: uint }
  {
    id: uint,
    customer: principal,
    provider: (optional principal),
    price: uint,
    category: uint,
    status: uint
  }
)

;; Per-provider liquidity and earnings
(define-map provider-liquidity
  { provider: principal }
  {
    total: uint,
    locked: uint,
    earnings: uint
  }
)

;; Internal helper to validate a job category
(define-private (is-valid-category (category uint))
  (or (is-eq category CATEGORY_POST_RENOVATION)
      (is-eq category CATEGORY_BEREAVEMENT)
      (is-eq category CATEGORY_CHILD_GEAR)))

;; Read-only views

(define-read-only (get-last-job-id)
  (var-get last-job-id)
)

(define-read-only (get-job (job-id uint))
  (map-get? jobs { id: job-id })
)

(define-read-only (get-provider-liquidity (who principal))
  (default-to
    { total: u0, locked: u0, earnings: u0 }
    (map-get? provider-liquidity { provider: who }))
)

(define-read-only (get-free-liquidity (who principal))
  (let ((liquidity (get-provider-liquidity who)))
    (- (get total liquidity) (get locked liquidity)))
)

;; Liquidity functions

(define-public (deposit-liquidity (amount uint))
  (begin
    (asserts! (> amount u0) (err ERR_ZERO_AMOUNT))
    ;; move STX from caller to contract as escrowed liquidity
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (let ((existing (get-provider-liquidity tx-sender)))
      (map-set provider-liquidity { provider: tx-sender }
        {
          total: (+ (get total existing) amount),
          locked: (get locked existing),
          earnings: (get earnings existing)
        })
      (ok (+ (get total existing) amount)))
  )
)

(define-public (withdraw-liquidity (amount uint))
  (let (
        (info (get-provider-liquidity tx-sender))
        (free (- (get total info) (get locked info)))
       )
    (begin
      (asserts! (> amount u0) (err ERR_ZERO_AMOUNT))
      (asserts! (>= free amount) (err ERR_WITHDRAW_TOO_MUCH))
      (let ((recipient tx-sender))
        (map-set provider-liquidity { provider: tx-sender }
          {
            total: (- (get total info) amount),
            locked: (get locked info),
            earnings: (get earnings info)
          })
        (try! (as-contract (stx-transfer? amount tx-sender recipient)))
        (ok (- (get total info) amount))
      ))
  )
)

;; Job lifecycle

(define-public (create-job (category uint) (price uint))
  (begin
    (asserts! (> price u0) (err ERR_ZERO_AMOUNT))
    (asserts! (is-valid-category category) (err ERR_INVALID_CATEGORY))
    (let ((new-id (+ (var-get last-job-id) u1)))
      (var-set last-job-id new-id)
      (map-set jobs { id: new-id }
        {
          id: new-id,
          customer: tx-sender,
          provider: none,
          price: price,
          category: category,
          status: STATUS_OPEN
        })
      ;; escrow the price in the contract
      (stx-transfer? price tx-sender (as-contract tx-sender))
    )
  )
)

(define-public (cancel-job (job-id uint))
  (match (map-get? jobs { id: job-id }) job
    (begin
      (asserts! (is-eq (get customer job) tx-sender) (err ERR_NOT_CUSTOMER))
      (asserts! (is-eq (get status job) STATUS_OPEN) (err ERR_INVALID_STATUS))
      ;; refund escrow to customer
      (try! (as-contract (stx-transfer? (get price job) tx-sender (get customer job))))
      (map-set jobs { id: job-id }
        (merge job { status: STATUS_CANCELLED }))
      (ok job-id)
    )
    (err ERR_JOB_NOT_FOUND)
  )
)

(define-public (accept-job (job-id uint))
  (match (map-get? jobs { id: job-id }) job
    (let (
          (info (get-provider-liquidity tx-sender))
          (free (- (get total info) (get locked info)))
         )
      (begin
        (asserts! (> (get total info) u0) (err ERR_NOT_PROVIDER))
        (asserts! (is-eq (get status job) STATUS_OPEN) (err ERR_INVALID_STATUS))
        (asserts! (>= free (get price job)) (err ERR_INSUFFICIENT_LIQUIDITY))
        (map-set provider-liquidity { provider: tx-sender }
          {
            total: (get total info),
            locked: (+ (get locked info) (get price job)),
            earnings: (get earnings info)
          })
        (map-set jobs { id: job-id }
          (merge job { provider: (some tx-sender), status: STATUS_ACCEPTED }))
        (ok job-id)
      )
    )
    (err ERR_JOB_NOT_FOUND)
  )
)

(define-public (complete-job (job-id uint))
  (match (map-get? jobs { id: job-id }) job
    (begin
      (asserts! (is-eq (get customer job) tx-sender) (err ERR_NOT_CUSTOMER))
      (asserts! (is-eq (get status job) STATUS_ACCEPTED) (err ERR_NOT_ACCEPTED))
      (match (get provider job) provider-principal
        (let (
              (info (get-provider-liquidity provider-principal))
              (price (get price job))
             )
          (begin
            ;; unlock provider liquidity and add earnings
            (map-set provider-liquidity { provider: provider-principal }
              {
                total: (get total info),
                locked: (- (get locked info) price),
                earnings: (+ (get earnings info) price)
              })
            ;; pay out from escrow to provider
            (try! (as-contract (stx-transfer? price tx-sender provider-principal)))
            (map-set jobs { id: job-id }
              (merge job { status: STATUS_COMPLETED }))
            (ok job-id)
          )
        )
        (err ERR_INVALID_STATUS)
      )
    )
    (err ERR_JOB_NOT_FOUND)
  )
)
