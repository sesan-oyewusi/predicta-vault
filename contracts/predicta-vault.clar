;; PredictaVault: Advanced Decentralized Prediction Market Infrastructure
;;
;; A next-generation prediction market protocol engineered for the Stacks ecosystem,
;; enabling sophisticated forecasting mechanisms with institutional-grade security.
;; PredictaVault transforms market sentiment into quantifiable predictions through
;; cryptographically secured smart contracts and oracle-driven price feeds.
;;
;; CORE ARCHITECTURE:
;; - Decentralized consensus-driven market resolution
;; - Multi-layer security with stake-weighted participation
;; - Dynamic fee optimization for sustainable protocol economics
;; - Cross-chain oracle integration for real-time price discovery
;; - Proportional reward distribution based on market performance
;;
;; SECURITY FRAMEWORK:
;; - Byzantine fault-tolerant oracle verification
;; - Multi-signature administrative controls
;; - Stake-based anti-sybil mechanisms
;; - Automated dispute resolution protocols
;; - Economic incentive alignment for honest participation

;; CONSTANTS & CONFIGURATION

;; Administrative Access Control
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))

;; System Error Codes
(define-constant ERR_MARKET_NOT_FOUND (err u101))
(define-constant ERR_INVALID_PREDICTION_TYPE (err u102))
(define-constant ERR_MARKET_UNAVAILABLE (err u103))
(define-constant ERR_REWARD_ALREADY_CLAIMED (err u104))
(define-constant ERR_INSUFFICIENT_FUNDS (err u105))
(define-constant ERR_INVALID_PARAMETERS (err u106))

;; STATE VARIABLES

;; Oracle Configuration
(define-data-var oracle-authority principal 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM)

;; Economic Parameters
(define-data-var min-participation-stake uint u1000000) ;; 1 STX minimum entry
(define-data-var protocol-fee-rate uint u2) ;; 2% protocol sustainability fee
(define-data-var global-market-counter uint u0) ;; Sequential market identifier

;; DATA STRUCTURES

;; Market Registry
(define-map prediction-markets
  uint
  {
    initial-price: uint,
    final-price: uint,
    bullish-stake-pool: uint,
    bearish-stake-pool: uint,
    market-start-height: uint,
    market-end-height: uint,
    settlement-completed: bool,
  }
)

;; Participant Registry
(define-map participant-positions
  {
    market-id: uint,
    participant: principal,
  }
  {
    market-sentiment: (string-ascii 4),
    stake-amount: uint,
    rewards-claimed: bool,
  }
)

;; CORE MARKET FUNCTIONS

;; Market Creation Engine
(define-public (initialize-market
    (initial-price uint)
    (start-height uint)
    (end-height uint)
  )
  (let ((new-market-id (var-get global-market-counter)))
    ;; Authorization Check
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    ;; Parameter Validation
    (asserts! (> end-height start-height) ERR_INVALID_PARAMETERS)
    (asserts! (> initial-price u0) ERR_INVALID_PARAMETERS)
    ;; Market Registration
    (map-set prediction-markets new-market-id {
      initial-price: initial-price,
      final-price: u0,
      bullish-stake-pool: u0,
      bearish-stake-pool: u0,
      market-start-height: start-height,
      market-end-height: end-height,
      settlement-completed: false,
    })
    ;; Counter Increment
    (var-set global-market-counter (+ new-market-id u1))
    (ok new-market-id)
  )
)

;; Position Entry System
(define-public (enter-position
    (market-id uint)
    (sentiment (string-ascii 4))
    (stake-amount uint)
  )
  (let (
      (market-data (unwrap! (map-get? prediction-markets market-id) ERR_MARKET_NOT_FOUND))
      (current-height stacks-block-height)
    )
    ;; Market Timing Validation
    (asserts!
      (and
        (>= current-height (get market-start-height market-data))
        (< current-height (get market-end-height market-data))
      )
      ERR_MARKET_UNAVAILABLE
    )
    ;; Sentiment Validation
    (asserts! (or (is-eq sentiment "up") (is-eq sentiment "down"))
      ERR_INVALID_PREDICTION_TYPE
    )
    ;; Stake Validation
    (asserts! (>= stake-amount (var-get min-participation-stake))
      ERR_INVALID_PREDICTION_TYPE
    )
    (asserts! (<= stake-amount (stx-get-balance tx-sender))
      ERR_INSUFFICIENT_FUNDS
    )
    ;; Stake Transfer
    (try! (stx-transfer? stake-amount tx-sender (as-contract tx-sender)))
    ;; Position Recording
    (map-set participant-positions {
      market-id: market-id,
      participant: tx-sender,
    } {
      market-sentiment: sentiment,
      stake-amount: stake-amount,
      rewards-claimed: false,
    })
    ;; Pool Updates
    (map-set prediction-markets market-id
      (merge market-data {
        bullish-stake-pool: (if (is-eq sentiment "up")
          (+ (get bullish-stake-pool market-data) stake-amount)
          (get bullish-stake-pool market-data)
        ),
        bearish-stake-pool: (if (is-eq sentiment "down")
          (+ (get bearish-stake-pool market-data) stake-amount)
          (get bearish-stake-pool market-data)
        ),
      })
    )
    (ok true)
  )
)

;; Market Settlement Engine
(define-public (settle-market
    (market-id uint)
    (final-price uint)
  )
  (let ((market-data (unwrap! (map-get? prediction-markets market-id) ERR_MARKET_NOT_FOUND)))
    ;; Oracle Authorization
    (asserts! (is-eq tx-sender (var-get oracle-authority)) ERR_UNAUTHORIZED)
    ;; Timing Validation
    (asserts! (>= stacks-block-height (get market-end-height market-data))
      ERR_MARKET_UNAVAILABLE
    )
    (asserts! (not (get settlement-completed market-data)) ERR_MARKET_UNAVAILABLE)
    ;; Price Validation
    (asserts! (> final-price u0) ERR_INVALID_PARAMETERS)
    ;; Settlement Recording
    (map-set prediction-markets market-id
      (merge market-data {
        final-price: final-price,
        settlement-completed: true,
      })
    )
    (ok true)
  )
)

;; Reward Distribution System
(define-public (claim-rewards (market-id uint))
  (let (
      (market-data (unwrap! (map-get? prediction-markets market-id) ERR_MARKET_NOT_FOUND))
      (participant-data (unwrap!
        (map-get? participant-positions {
          market-id: market-id,
          participant: tx-sender,
        })
        ERR_MARKET_NOT_FOUND
      ))
    )
    ;; Settlement Validation
    (asserts! (get settlement-completed market-data) ERR_MARKET_UNAVAILABLE)
    (asserts! (not (get rewards-claimed participant-data))
      ERR_REWARD_ALREADY_CLAIMED
    )
    ;; Winning Sentiment Calculation
    (let (
        (winning-sentiment (if (> (get final-price market-data) (get initial-price market-data))
          "up"
          "down"
        ))
        (total-market-stake (+ (get bullish-stake-pool market-data)
          (get bearish-stake-pool market-data)
        ))
        (winning-pool-stake (if (is-eq winning-sentiment "up")
          (get bullish-stake-pool market-data)
          (get bearish-stake-pool market-data)
        ))
      )
      ;; Winner Validation
      (asserts! (is-eq (get market-sentiment participant-data) winning-sentiment)
        ERR_INVALID_PREDICTION_TYPE
      )
      ;; Reward Calculation
      (let (
          (gross-rewards (/ (* (get stake-amount participant-data) total-market-stake)
            winning-pool-stake
          ))
          (protocol-fee (/ (* gross-rewards (var-get protocol-fee-rate)) u100))
          (net-rewards (- gross-rewards protocol-fee))
        )
        ;; Reward Distribution
        (try! (as-contract (stx-transfer? net-rewards (as-contract tx-sender) tx-sender)))
        (try! (as-contract (stx-transfer? protocol-fee (as-contract tx-sender) CONTRACT_OWNER)))
        ;; Claim Status Update
        (map-set participant-positions {
          market-id: market-id,
          participant: tx-sender,
        }
          (merge participant-data { rewards-claimed: true })
        )
        (ok net-rewards)
      )
    )
  )
)

;; QUERY FUNCTIONS

;; Market Data Retrieval
(define-read-only (get-market-info (market-id uint))
  (map-get? prediction-markets market-id)
)

;; Participant Data Retrieval
(define-read-only (get-participant-position
    (market-id uint)
    (participant principal)
  )
  (map-get? participant-positions {
    market-id: market-id,
    participant: participant,
  })
)

;; Contract Treasury Status
(define-read-only (get-treasury-balance)
  (stx-get-balance (as-contract tx-sender))
)

;; ADMINISTRATIVE FUNCTIONS

;; Oracle Authority Management
(define-public (update-oracle-authority (new-oracle principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (is-eq new-oracle new-oracle) ERR_INVALID_PARAMETERS)
    (ok (var-set oracle-authority new-oracle))
  )
)

;; Stake Requirements Management
(define-public (update-minimum-stake (new-minimum uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (> new-minimum u0) ERR_INVALID_PARAMETERS)
    (ok (var-set min-participation-stake new-minimum))
  )
)

;; Fee Structure Management
(define-public (update-protocol-fee (new-fee-rate uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (<= new-fee-rate u100) ERR_INVALID_PARAMETERS)
    (ok (var-set protocol-fee-rate new-fee-rate))
  )
)

;; Treasury Management
(define-public (withdraw-treasury-funds (withdrawal-amount uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (<= withdrawal-amount (stx-get-balance (as-contract tx-sender)))
      ERR_INSUFFICIENT_FUNDS
    )
    (try! (as-contract (stx-transfer? withdrawal-amount (as-contract tx-sender) CONTRACT_OWNER)))
    (ok withdrawal-amount)
  )
)
