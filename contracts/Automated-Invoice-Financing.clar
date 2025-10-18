;; title: Automated-Invoice-Financing
;; version: 1.0.0
;; summary: Smart contract for automated invoice financing and factoring
;; description: Enables businesses to factor invoices for immediate liquidity while providing investment opportunities

;; constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-insufficient-funds (err u102))
(define-constant err-already-exists (err u103))
(define-constant err-unauthorized (err u104))
(define-constant err-invalid-amount (err u105))
(define-constant err-invalid-duration (err u106))
(define-constant err-invoice-expired (err u107))
(define-constant err-already-funded (err u108))
(define-constant err-not-due (err u109))
(define-constant err-already-paid (err u110))

(define-constant min-invoice-amount u1000)
(define-constant max-invoice-amount u10000000)
(define-constant min-duration u144)
(define-constant max-duration u4320)
(define-constant platform-fee-rate u250)
(define-constant base-interest-rate u500)

;; extension settings
(define-constant max-extension u720)            ;; maximum extra blocks allowed for due-date extension
(define-constant extension-fee-rate u75)        ;; 0.75% of invoice amount paid to investor on extension

;; batch processing settings
(define-constant max-batch-size u10)            ;; maximum invoices per batch operation
(define-constant batch-discount-rate u50)       ;; 0.5% discount on interest for batch operations

;; data vars
(define-data-var next-invoice-id uint u1)
(define-data-var total-invoices-funded uint u0)
(define-data-var total-volume uint u0)
(define-data-var platform-treasury uint u0)
(define-data-var next-batch-id uint u1)
(define-data-var total-batch-operations uint u0)

;; data maps
(define-map invoices
  uint
  {
    business: principal,
    debtor: principal,
    amount: uint,
    funded-amount: uint,
    interest-rate: uint,
    created-at: uint,
    due-at: uint,
    funded-at: (optional uint),
    paid-at: (optional uint),
    investor: (optional principal),
    status: (string-ascii 20)
  }
)

(define-map business-profiles
  principal
  {
    total-invoices: uint,
    total-funded: uint,
    reputation-score: uint,
    default-count: uint,
    active: bool
  }
)

(define-map investor-profiles
  principal
  {
    total-invested: uint,
    total-earned: uint,
    active-investments: uint
  }
)

(define-map invoice-payments
  uint
  {
    amount-paid: uint,
    payment-date: uint,
    payer: principal
  }
)

;; one-time extension records per invoice
(define-map invoice-extensions
  uint
  {
    extra-duration: uint,        ;; blocks added to due-at
    fee: uint,                   ;; extension fee amount paid
    extended-at: uint,           ;; block height when extension applied
    extended-by: principal       ;; debtor who requested extension
  }
)

(define-map batch-operations
  uint
  {
    creator: principal,
    invoice-ids: (list 10 uint),
    total-amount: uint,
    created-at: uint,
    operation-type: (string-ascii 10)
  }
)

(define-map invoice-batches
  uint
  uint
)

;; public functions
(define-public (create-batch-invoices (invoice-data (list 10 {debtor: principal, amount: uint, duration: uint})))
  (let
    (
      (batch-id (var-get next-batch-id))
      (current-block stacks-block-height)
      (batch-size (len invoice-data))
    )
    (asserts! (<= batch-size max-batch-size) err-invalid-amount)
    (asserts! (> batch-size u0) err-invalid-amount)
    
    (let
      (
        (invoice-ids (unwrap! (create-invoices-from-batch invoice-data current-block batch-id) err-invalid-amount))
        (total-batch-amount (fold + (map get-invoice-amount invoice-data) u0))
      )
      (map-set batch-operations batch-id {
        creator: tx-sender,
        invoice-ids: invoice-ids,
        total-amount: total-batch-amount,
        created-at: current-block,
        operation-type: "create"
      })
      
      (var-set next-batch-id (+ batch-id u1))
      (var-set total-batch-operations (+ (var-get total-batch-operations) u1))
      (ok {batch-id: batch-id, invoice-ids: invoice-ids})
    )
  )
)

(define-public (create-invoice (debtor principal) (amount uint) (duration uint))
  (let
    (
      (invoice-id (var-get next-invoice-id))
      (current-block stacks-block-height)
      (due-block (+ current-block duration))
    )
    (asserts! (>= amount min-invoice-amount) err-invalid-amount)
    (asserts! (<= amount max-invoice-amount) err-invalid-amount)
    (asserts! (>= duration min-duration) err-invalid-duration)
    (asserts! (<= duration max-duration) err-invalid-duration)
    (asserts! (not (is-eq tx-sender debtor)) err-unauthorized)
    
    (map-set invoices invoice-id {
      business: tx-sender,
      debtor: debtor,
      amount: amount,
      funded-amount: u0,
      interest-rate: (calculate-interest-rate tx-sender amount),
      created-at: current-block,
      due-at: due-block,
      funded-at: none,
      paid-at: none,
      investor: none,
      status: "pending"
    })
    
    (update-business-profile tx-sender)
    (var-set next-invoice-id (+ invoice-id u1))
    (ok invoice-id)
  )
)

(define-public (fund-batch-invoices (invoice-ids (list 10 uint)))
  (let
    (
      (batch-id (var-get next-batch-id))
      (current-block stacks-block-height)
      (batch-size (len invoice-ids))
    )
    (asserts! (<= batch-size max-batch-size) err-invalid-amount)
    (asserts! (> batch-size u0) err-invalid-amount)
    
    (let
      (
        (funding-results (unwrap! (fund-invoices-from-batch invoice-ids current-block) err-insufficient-funds))
        (total-funded (get total-amount funding-results))
      )
      (map-set batch-operations batch-id {
        creator: tx-sender,
        invoice-ids: invoice-ids,
        total-amount: total-funded,
        created-at: current-block,
        operation-type: "fund"
      })
      
      (var-set next-batch-id (+ batch-id u1))
      (var-set total-batch-operations (+ (var-get total-batch-operations) u1))
      (ok {batch-id: batch-id, funded-count: (get funded-count funding-results), total-amount: total-funded})
    )
  )
)

(define-public (fund-invoice (invoice-id uint))
  (let
    (
      (invoice (unwrap! (map-get? invoices invoice-id) err-not-found))
      (funding-amount (calculate-funding-amount (get amount invoice) (get interest-rate invoice)))
      (current-block stacks-block-height)
    )
    (asserts! (is-eq (get status invoice) "pending") err-already-funded)
    (asserts! (< current-block (get due-at invoice)) err-invoice-expired)
    (asserts! (>= (stx-get-balance tx-sender) funding-amount) err-insufficient-funds)
    
    (try! (stx-transfer? funding-amount tx-sender (get business invoice)))
    
    (map-set invoices invoice-id 
      (merge invoice {
        funded-amount: funding-amount,
        funded-at: (some current-block),
        investor: (some tx-sender),
        status: "funded"
      })
    )
    
    (update-investor-profile tx-sender funding-amount)
    (var-set total-invoices-funded (+ (var-get total-invoices-funded) u1))
    (var-set total-volume (+ (var-get total-volume) funding-amount))
    (ok true)
  )
)

(define-public (pay-invoice (invoice-id uint))
  (let
    (
      (invoice (unwrap! (map-get? invoices invoice-id) err-not-found))
      (payment-amount (+ (get amount invoice) (calculate-interest (get amount invoice) (get interest-rate invoice))))
      (platform-fee (/ (* payment-amount platform-fee-rate) u10000))
      (investor-payout (- payment-amount platform-fee))
      (current-block stacks-block-height)
    )
    (asserts! (is-eq (get status invoice) "funded") err-not-found)
    (asserts! (>= current-block (get due-at invoice)) err-not-due)
    (asserts! (>= (stx-get-balance tx-sender) payment-amount) err-insufficient-funds)
    
    (try! (stx-transfer? platform-fee tx-sender contract-owner))
    (try! (stx-transfer? investor-payout tx-sender (unwrap-panic (get investor invoice))))
    
    (map-set invoices invoice-id 
      (merge invoice {
        paid-at: (some current-block),
        status: "paid"
      })
    )
    
    (map-set invoice-payments invoice-id {
      amount-paid: payment-amount,
      payment-date: current-block,
      payer: tx-sender
    })
    
    (var-set platform-treasury (+ (var-get platform-treasury) platform-fee))
    (update-investor-earnings (unwrap-panic (get investor invoice)) investor-payout)
    (ok true)
  )
)

;; Debtor can extend due date once by paying a small fee to the investor
(define-public (extend-due-date (invoice-id uint) (extra-duration uint))
  (let
    (
      (invoice (unwrap! (map-get? invoices invoice-id) err-not-found))
      (current-block stacks-block-height)
      (fee (/ (* (get amount invoice) extension-fee-rate) u10000))
    )
    (asserts! (is-eq tx-sender (get debtor invoice)) err-unauthorized)
    (asserts! (is-eq (get status invoice) "funded") err-not-found)
    (asserts! (< current-block (get due-at invoice)) err-not-due)
    (asserts! (<= extra-duration max-extension) err-invalid-duration)
    (asserts! (is-none (map-get? invoice-extensions invoice-id)) err-already-exists)
    (asserts! (>= (stx-get-balance tx-sender) fee) err-insufficient-funds)

    ;; pay fee directly to the investor as compensation for extended term
    (try! (stx-transfer? fee tx-sender (unwrap-panic (get investor invoice))))

    ;; update invoice due-at
    (map-set invoices invoice-id
      (merge invoice {
        due-at: (+ (get due-at invoice) extra-duration)
      })
    )

    ;; record extension details for auditability
    (map-set invoice-extensions invoice-id {
      extra-duration: extra-duration,
      fee: fee,
      extended-at: current-block,
      extended-by: tx-sender
    })
    (ok true)
  )
)

(define-public (mark-default (invoice-id uint))
  (let
    (
      (invoice (unwrap! (map-get? invoices invoice-id) err-not-found))
      (current-block stacks-block-height)
    )
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (is-eq (get status invoice) "funded") err-not-found)
    (asserts! (> current-block (+ (get due-at invoice) u1440)) err-not-due)
    
    (map-set invoices invoice-id 
      (merge invoice {
        status: "defaulted"
      })
    )
    
    (update-business-default (get business invoice))
    (ok true)
  )
)

(define-public (withdraw-platform-fees)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (let ((amount (var-get platform-treasury)))
      (var-set platform-treasury u0)
      (try! (as-contract (stx-transfer? amount tx-sender contract-owner)))
      (ok amount)
    )
  )
)

;; read only functions
(define-read-only (get-invoice (invoice-id uint))
  (map-get? invoices invoice-id)
)

(define-read-only (get-business-profile (business principal))
  (map-get? business-profiles business)
)

(define-read-only (get-investor-profile (investor principal))
  (map-get? investor-profiles investor)
)

(define-read-only (get-platform-stats)
  {
    total-invoices: (- (var-get next-invoice-id) u1),
    total-funded: (var-get total-invoices-funded),
    total-volume: (var-get total-volume),
    platform-treasury: (var-get platform-treasury)
  }
)

(define-read-only (calculate-funding-amount (amount uint) (interest-rate uint))
  (- amount (/ (* amount interest-rate) u10000))
)

(define-read-only (calculate-interest (amount uint) (rate uint))
  (/ (* amount rate) u10000)
)

(define-read-only (calculate-interest-rate (business principal) (amount uint))
  (let
    (
      (profile (default-to 
        {total-invoices: u0, total-funded: u0, reputation-score: u500, default-count: u0, active: true}
        (map-get? business-profiles business)
      ))
      (reputation-adjustment (if (> (get reputation-score profile) u700) u0 u200))
      (amount-adjustment (if (> amount u100000) u0 u100))
      (default-penalty (* (get default-count profile) u300))
    )
    (+ base-interest-rate reputation-adjustment amount-adjustment default-penalty)
  )
)

(define-read-only (get-invoice-payment (invoice-id uint))
  (map-get? invoice-payments invoice-id)
)

(define-read-only (get-invoice-extension (invoice-id uint))
  (map-get? invoice-extensions invoice-id)
)

(define-read-only (get-batch-operation (batch-id uint))
  (map-get? batch-operations batch-id)
)

(define-read-only (get-invoice-batch (invoice-id uint))
  (map-get? invoice-batches invoice-id)
)

(define-read-only (get-batch-invoices (invoice-ids (list 10 uint)))
  (map get-invoice invoice-ids)
)

(define-read-only (get-batch-stats)
  {
    total-batch-operations: (var-get total-batch-operations),
    next-batch-id: (var-get next-batch-id)
  }
)

;; private functions
(define-private (update-business-profile (business principal))
  (let
    (
      (current-profile (default-to 
        {total-invoices: u0, total-funded: u0, reputation-score: u500, default-count: u0, active: true}
        (map-get? business-profiles business)
      ))
    )
    (map-set business-profiles business
      (merge current-profile {
        total-invoices: (+ (get total-invoices current-profile) u1)
      })
    )
  )
)

(define-private (update-investor-profile (investor principal) (amount uint))
  (let
    (
      (current-profile (default-to 
        {total-invested: u0, total-earned: u0, active-investments: u0}
        (map-get? investor-profiles investor)
      ))
    )
    (map-set investor-profiles investor
      (merge current-profile {
        total-invested: (+ (get total-invested current-profile) amount),
        active-investments: (+ (get active-investments current-profile) u1)
      })
    )
  )
)

(define-private (update-investor-earnings (investor principal) (earnings uint))
  (let
    (
      (current-profile (unwrap-panic (map-get? investor-profiles investor)))
    )
    (map-set investor-profiles investor
      (merge current-profile {
        total-earned: (+ (get total-earned current-profile) earnings),
        active-investments: (- (get active-investments current-profile) u1)
      })
    )
  )
)

(define-private (update-business-default (business principal))
  (let
    (
      (current-profile (unwrap-panic (map-get? business-profiles business)))
    )
    (map-set business-profiles business
      (merge current-profile {
        default-count: (+ (get default-count current-profile) u1),
        reputation-score: (if (> (get reputation-score current-profile) u100) 
                           (- (get reputation-score current-profile) u100) u0)
      })
    )
  )
)

(define-private (create-invoices-from-batch (invoice-data (list 10 {debtor: principal, amount: uint, duration: uint})) (current-block uint) (batch-id uint))
  (ok (unwrap! (fold create-invoice-from-data invoice-data (ok (list))) err-invalid-amount))
)

(define-private (create-invoice-from-data (data {debtor: principal, amount: uint, duration: uint}) (acc (response (list 10 uint) uint)))
  (match acc
    success-list
    (let
      (
        (invoice-id (var-get next-invoice-id))
        (current-block stacks-block-height)
        (due-block (+ current-block (get duration data)))
        (batch-adjusted-rate (- (calculate-interest-rate tx-sender (get amount data)) batch-discount-rate))
      )
      (asserts! (>= (get amount data) min-invoice-amount) err-invalid-amount)
      (asserts! (<= (get amount data) max-invoice-amount) err-invalid-amount)
      (asserts! (>= (get duration data) min-duration) err-invalid-duration)
      (asserts! (<= (get duration data) max-duration) err-invalid-duration)
      (asserts! (not (is-eq tx-sender (get debtor data))) err-unauthorized)
      
      (map-set invoices invoice-id {
        business: tx-sender,
        debtor: (get debtor data),
        amount: (get amount data),
        funded-amount: u0,
        interest-rate: batch-adjusted-rate,
        created-at: current-block,
        due-at: due-block,
        funded-at: none,
        paid-at: none,
        investor: none,
        status: "pending"
      })
      
      (update-business-profile tx-sender)
      (var-set next-invoice-id (+ invoice-id u1))
      (ok (unwrap! (as-max-len? (append success-list invoice-id) u10) err-invalid-amount))
    )
    error-val (err error-val)
  )
)

(define-private (fund-invoices-from-batch (invoice-ids (list 10 uint)) (current-block uint))
  (fold fund-single-invoice-in-batch invoice-ids (ok {funded-count: u0, total-amount: u0}))
)

(define-private (fund-single-invoice-in-batch (invoice-id uint) (acc (response {funded-count: uint, total-amount: uint} uint)))
  (match acc
    success-data
    (match (fund-invoice invoice-id)
      success-result
      (let
        (
          (invoice (unwrap-panic (map-get? invoices invoice-id)))
          (funding-amount (get funded-amount invoice))
        )
        (ok {
          funded-count: (+ (get funded-count success-data) u1),
          total-amount: (+ (get total-amount success-data) funding-amount)
        })
      )
      error-val acc
    )
    error-val (err error-val)
  )
)

(define-private (get-invoice-amount (data {debtor: principal, amount: uint, duration: uint}))
  (get amount data)
)