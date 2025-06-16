;; Title: StacksCredit - Decentralized Credit Protocol
;;
;; Summary: A trustless, Bitcoin-secured lending protocol that revolutionizes 
;; DeFi credit markets through dynamic risk assessment and collateral management
;;
;; Description: StacksCredit is an innovative Layer 2 lending protocol built on 
;; Stacks that brings traditional credit mechanics to Bitcoin DeFi. The protocol 
;; features dynamic credit scoring, risk-based collateral requirements, and 
;; automated liquidation mechanisms. Users can establish creditworthiness through 
;; successful loan repayments, earning better rates and lower collateral requirements 
;; over time. Powered by Bitcoin's security and Stacks' smart contract capabilities, 
;; StacksCredit creates a sustainable, trustless lending ecosystem for the Bitcoin 
;; economy. Perfect for builders, traders, and institutions seeking efficient 
;; capital allocation with transparent, algorithmic risk management.

;; CONTRACT ADMINISTRATION

(define-constant CONTRACT-OWNER tx-sender)

;; ERROR CONSTANTS

(define-constant ERR-UNAUTHORIZED (err u1))
(define-constant ERR-INSUFFICIENT-BALANCE (err u2))
(define-constant ERR-INVALID-AMOUNT (err u3))
(define-constant ERR-LOAN-NOT-FOUND (err u4))
(define-constant ERR-LOAN-DEFAULTED (err u5))
(define-constant ERR-INSUFFICIENT-SCORE (err u6))
(define-constant ERR-ACTIVE-LOAN (err u7))
(define-constant ERR-NOT-DUE (err u8))
(define-constant ERR-INVALID-DURATION (err u9))
(define-constant ERR-INVALID-LOAN-ID (err u10))

;; PROTOCOL PARAMETERS

;; Credit Score Boundaries
(define-constant MIN-SCORE u50)           ;; Minimum possible credit score
(define-constant MAX-SCORE u100)          ;; Maximum possible credit score
(define-constant MIN-LOAN-SCORE u70)      ;; Minimum score required for loan eligibility

;; DATA STORAGE LAYER

;; User Credit Profiles
;; Comprehensive tracking of individual user credit metrics and lending history
(define-map UserScores
  { user: principal }
  {
    score: uint,
    total-borrowed: uint,
    total-repaid: uint,
    loans-taken: uint,
    loans-repaid: uint,
    last-update: uint,
  }
)

;; Loan Registry
;; Complete loan lifecycle management with collateral and repayment tracking
(define-map Loans
  { loan-id: uint }
  {
    borrower: principal,
    amount: uint,
    collateral: uint,
    due-height: uint,
    interest-rate: uint,
    is-active: bool,
    is-defaulted: bool,
    repaid-amount: uint,
  }
)

;; User Active Loans Mapping
;; Efficient tracking of user's concurrent loan positions (max 20 loans per user)
(define-map UserLoans
  { user: principal }
  { active-loans: (list 20 uint) }
)

;; PROTOCOL STATE VARIABLES

;; Auto-incrementing unique loan identifier
(define-data-var next-loan-id uint u0)

;; Total STX collateral locked in the protocol
(define-data-var total-stx-locked uint u0)

;; PUBLIC INTERFACE FUNCTIONS

;; Initialize User Credit Profile
;; Bootstraps credit scoring system for new protocol participants
(define-public (initialize-score)
  (let ((sender tx-sender))
    (asserts! (is-none (map-get? UserScores { user: sender })) ERR-UNAUTHORIZED)
    (ok (map-set UserScores { user: sender } {
      score: MIN-SCORE,
      total-borrowed: u0,
      total-repaid: u0,
      loans-taken: u0,
      loans-repaid: u0,
      last-update: stacks-block-height,
    }))
  )
)

;; Request New Loan
;; Core lending function with dynamic risk assessment and collateral validation
(define-public (request-loan
    (amount uint)
    (collateral uint)
    (duration uint)
  )
  (let (
      (sender tx-sender)
      (loan-id (+ (var-get next-loan-id) u1))
      (user-score (unwrap! (map-get? UserScores { user: sender }) ERR-UNAUTHORIZED))
      (active-loans (default-to { active-loans: (list) } (map-get? UserLoans { user: sender })))
    )
    ;; Risk Assessment & Validation Layer
    (asserts! (>= (get score user-score) MIN-LOAN-SCORE) ERR-INSUFFICIENT-SCORE)
    (asserts! (<= (len (get active-loans active-loans)) u5) ERR-ACTIVE-LOAN)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (and (> duration u0) (<= duration u52560)) ERR-INVALID-DURATION)
    ;; Maximum ~1 year assuming 10-minute blocks
    
    ;; Dynamic Collateral Calculation & Validation
    (let ((required-collateral (calculate-required-collateral amount (get score user-score))))
      (asserts! (>= collateral required-collateral) ERR-INSUFFICIENT-BALANCE)
      
      ;; Secure Collateral Transfer
      (try! (stx-transfer? collateral sender (as-contract tx-sender)))
      
      ;; Loan Record Creation
      (map-set Loans { loan-id: loan-id } {
        borrower: sender,
        amount: amount,
        collateral: collateral,
        due-height: (+ stacks-block-height duration),
        interest-rate: (calculate-interest-rate (get score user-score)),
        is-active: true,
        is-defaulted: false,
        repaid-amount: u0,
      })
      
      ;; User Loan Portfolio Update
      (try! (update-user-loans sender loan-id))
      
      ;; Loan Disbursement
      (as-contract (try! (stx-transfer? amount tx-sender sender)))
      
      ;; Protocol State Updates
      (var-set next-loan-id loan-id)
      (var-set total-stx-locked (+ (var-get total-stx-locked) collateral))
      
      (ok loan-id)
    )
  )
)

;; Repay Loan
;; Flexible repayment system supporting partial and full loan settlement
(define-public (repay-loan
    (loan-id uint)
    (amount uint)
  )
  (let (
      (sender tx-sender)
      (loan (unwrap! (map-get? Loans { loan-id: loan-id }) ERR-LOAN-NOT-FOUND))
    )
    ;; Authorization & Loan Status Validation
    (asserts! (is-eq sender (get borrower loan)) ERR-UNAUTHORIZED)
    (asserts! (get is-active loan) ERR-LOAN-NOT-FOUND)
    (asserts! (not (get is-defaulted loan)) ERR-LOAN-DEFAULTED)
    (asserts! (<= loan-id (var-get next-loan-id)) ERR-INVALID-LOAN-ID)
    
    ;; Repayment Processing Logic
    (let ((total-due (calculate-total-due loan)))
      (asserts! (>= amount u0) ERR-INVALID-AMOUNT)
      
      ;; Secure Payment Transfer
      (try! (stx-transfer? amount sender (as-contract tx-sender)))
      
      ;; Loan Status Update
      (let ((new-repaid-amount (+ (get repaid-amount loan) amount)))
        (map-set Loans { loan-id: loan-id }
          (merge loan {
            repaid-amount: new-repaid-amount,
            is-active: (< new-repaid-amount total-due),
          })
        )
        
        ;; Full Repayment Settlement
        (if (>= new-repaid-amount total-due)
          (begin
            ;; Positive Credit Score Adjustment
            (try! (update-credit-score sender true loan))
            ;; Collateral Return
            (as-contract (try! (stx-transfer? (get collateral loan) tx-sender sender)))
            ;; Protocol Collateral Counter Update
            (var-set total-stx-locked
              (- (var-get total-stx-locked) (get collateral loan))
            )
          )
          true
        )
        
        (ok true)
      )
    )
  )
)

;; INTERNAL CALCULATION FUNCTIONS

;; Calculate Required Collateral
;; Dynamic collateral ratio based on creditworthiness
;; Higher credit scores unlock lower collateral requirements
(define-private (calculate-required-collateral
    (amount uint)
    (score uint)
  )
  (let ((collateral-ratio (- u100 (/ (* score u50) u100))))
    (/ (* amount collateral-ratio) u100)
  )
)

;; Calculate Interest Rate
;; Credit-score-based interest rate determination
;; Superior credit history rewards borrowers with reduced rates
(define-private (calculate-interest-rate (score uint))
  (let ((base-rate u10))
    (- base-rate (/ (* score u5) u100))
  )
)

;; Calculate Total Amount Due
;; Complete loan obligation including principal and accrued interest
(define-private (calculate-total-due (loan {
  borrower: principal,
  amount: uint,
  collateral: uint,
  due-height: uint,
  interest-rate: uint,
  is-active: bool,
  is-defaulted: bool,
  repaid-amount: uint,
}))
  (let ((interest (* (get amount loan) (get interest-rate loan))))
    (+ (get amount loan) (/ interest u100))
  )
)

;; Update Credit Score
;; Dynamic credit scoring engine with performance-based adjustments
;; Successful repayments build credit, defaults trigger penalties
(define-private (update-credit-score
    (user principal)
    (success bool)
    (loan {
      borrower: principal,
      amount: uint,
      collateral: uint,
      due-height: uint,
      interest-rate: uint,
      is-active: bool,
      is-defaulted: bool,
      repaid-amount: uint,
    })
  )
  (let (
      (current-score (unwrap! (map-get? UserScores { user: user }) ERR-UNAUTHORIZED))
      (new-score (if success
        (if (<= (+ (get score current-score) u2) MAX-SCORE)
          (+ (get score current-score) u2)
          MAX-SCORE
        )
        (if (>= (- (get score current-score) u10) MIN-SCORE)
          (- (get score current-score) u10)
          MIN-SCORE
        )
      ))
    )
    
    ;; Credit Profile Update Based on Performance
    (if success
      (map-set UserScores { user: user }
        (merge current-score {
          score: new-score,
          total-repaid: (+ (get total-repaid current-score) (get amount loan)),
          loans-repaid: (+ (get loans-repaid current-score) u1),
          last-update: stacks-block-height,
        })
      )
      (map-set UserScores { user: user }
        (merge current-score {
          score: new-score,
          last-update: stacks-block-height,
        })
      )
    )
    
    (ok true)
  )
)

;; Update User Active Loans
;; Efficient management of user's concurrent loan portfolio
(define-private (update-user-loans
    (user principal)
    (loan-id uint)
  )
  (let ((user-loans (default-to { active-loans: (list) } (map-get? UserLoans { user: user }))))
    (map-set UserLoans { user: user } { 
      active-loans: (unwrap! (as-max-len? (append (get active-loans user-loans) loan-id) u20)
        ERR-ACTIVE-LOAN
      ) 
    })
    (ok true)
  )
)

;; READ-ONLY QUERY FUNCTIONS

;; Get User Credit Score
;; Comprehensive credit profile retrieval for analytics and decisions
(define-read-only (get-user-score (user principal))
  (map-get? UserScores { user: user })
)

;; Get Loan Details
;; Complete loan information retrieval for monitoring and management
(define-read-only (get-loan (loan-id uint))
  (map-get? Loans { loan-id: loan-id })
)

;; Get User Active Loans
;; Active loan portfolio overview for borrowers and analytics
(define-read-only (get-user-active-loans (user principal))
  (map-get? UserLoans { user: user })
)

;; PROTOCOL ADMINISTRATION FUNCTIONS

;; Mark Loan as Defaulted
;; Administrative function for handling overdue loans with automated penalties
;; Triggers credit score reduction and collateral forfeiture for protocol protection
(define-public (mark-loan-defaulted (loan-id uint))
  (let ((loan (unwrap! (map-get? Loans { loan-id: loan-id }) ERR-LOAN-NOT-FOUND)))
    ;; Administrative Authorization & Timing Validation
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (>= stacks-block-height (get due-height loan)) ERR-NOT-DUE)
    (asserts! (get is-active loan) ERR-LOAN-NOT-FOUND)
    (asserts! (<= loan-id (var-get next-loan-id)) ERR-INVALID-LOAN-ID)
    
    ;; Loan Default Processing
    (map-set Loans { loan-id: loan-id }
      (merge loan {
        is-defaulted: true,
        is-active: false,
      })
    )
    
    ;; Credit Score Penalty Application
    (try! (update-credit-score (get borrower loan) false loan))
    
    (ok true)
  )
)