;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; 
;; File: CommitPool.clar (patched - Clarity v1 compatible)
;; Changes:
;; - Use block-height (Option B) instead of get-block-height/stacks-block-height
;; - Fix match syntax to (match input some-binding some-expr none-expr)
;; - Replace wildcard match bindings with named ones
;; - Add delegate-index and commits-by-voter maps
;; - Normalize error constants and usage
;; - Rename public function `delegate` -> `set-delegate` to avoid name conflict
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; 

(define-data-var poll-counter uint u0)

(define-map polls
  { id: uint }
  {
    creator: principal,
    commit-end: uint,
    reveal-end: uint,
    quorum: uint,
    status: uint,
    yes: uint,
    no: uint,
    commit-count: uint,
  }
)

;; indexable commit entries
(define-map commits
  {
    poll-id: uint,
    idx: uint,
  }
  {
    voter: principal,
    hash: (buff 32),
  }
)
;; last index per poll
(define-map commit-index
  { poll-id: uint }
  { last-idx: uint }
)

;; per-voter commit pointer for O(1) lookup and to prevent multiple commits
(define-map commits-by-voter
  {
    poll-id: uint,
    voter: principal,
  }
  {
    idx: uint,
    hash: (buff 32),
  }
)

(define-map reveals
  {
    poll-id: uint,
    voter: principal,
  }
  {
    revealed: bool,
    choice: bool,
  }
)
(define-map delegation
  { delegator: principal }
  { delegate: principal }
)
;; registry per-delegate (indexable)
(define-map delegates-list
  {
    delegate: principal,
    idx: uint,
  }
  { delegator: principal }
)
;; last index per delegate to append correctly
(define-map delegate-index
  { delegate: principal }
  { last-idx: uint }
)

;; Error constants
(define-constant ERR_INVALID_PARAMS (err u400))
(define-constant ERR_PHASE (err u500))
(define-constant ERR_ALREADY_COMMITTED (err u501))
(define-constant ERR_HASH_MISMATCH (err u502))
(define-constant ERR_ALREADY_REVEALED (err u503))
(define-constant ERR_INVALID_POLL (err u504))
(define-constant ERR_NO_RIGHTS (err u505))
(define-constant ERR_NO_COMMIT (err u507))

;; create-poll
(define-public (create-poll
    (commit-end uint)
    (reveal-end uint)
    (quorum uint)
  )
  (let (
      (now stacks-block-height)
      (id (+ (var-get poll-counter) u1))
    )
    (asserts! (> commit-end now) ERR_INVALID_PARAMS)
    (asserts! (> reveal-end commit-end) ERR_INVALID_PARAMS)
    (var-set poll-counter id)
    (map-set polls { id: id } {
      creator: tx-sender,
      commit-end: commit-end,
      reveal-end: reveal-end,
      quorum: quorum,
      status: u0,
      yes: u0,
      no: u0,
      commit-count: u0,
    })
    (print {
      event: "poll_created",
      id: id,
      creator: tx-sender,
      commit_end: commit-end,
      reveal_end: reveal-end,
      quorum: quorum,
    })
    (ok id)
  )
)

;; commit: store commit in indexable registry; enforce single commit per voter
(define-public (commit
    (poll-id uint)
    (hash (buff 32))
  )
  (let (
      (popt (map-get? polls { id: poll-id }))
      (now stacks-block-height)
    )
    (match popt
      p (begin
        (asserts! (<= now (get commit-end p)) ERR_PHASE)
        ;; prevent multiple commits from same voter
        (match (map-get? commits-by-voter {
          poll-id: poll-id,
          voter: tx-sender,
        })
          existing-commit
          ERR_ALREADY_COMMITTED (let (
              (last (default-to u0
                (get last-idx (map-get? commit-index { poll-id: poll-id }))
              ))
              (next (+ last u1))
              (new-count (+ (get commit-count p) u1))
            )
            (map-set commits {
              poll-id: poll-id,
              idx: next,
            } {
              voter: tx-sender,
              hash: hash,
            })
            (map-set commit-index { poll-id: poll-id } { last-idx: next })
            (map-set commits-by-voter {
              poll-id: poll-id,
              voter: tx-sender,
            } {
              idx: next,
              hash: hash,
            })
            (map-set polls { id: poll-id } (merge p { commit-count: new-count }))
            (print {
              event: "commit_stored",
              poll: poll-id,
              idx: next,
              voter: tx-sender,
            })
            (ok next)
          )
        )
      )
      ERR_INVALID_POLL
    )
  )
)

;; set-delegate: register delegation and registry entry for delegate
(define-public (set-delegate (to principal))
  (begin
    ;; Optional: prevent self-delegation
    (asserts! (not (is-eq to tx-sender)) ERR_INVALID_PARAMS)
    (map-set delegation { delegator: tx-sender } { delegate: to })
    ;; add delegator to delegate's list using delegate-index
    (let ((cur-idx (+
        (default-to u0 (get last-idx (map-get? delegate-index { delegate: to })))
        u1
      )))
      (map-set delegates-list {
        delegate: to,
        idx: cur-idx,
      } { delegator: tx-sender }
      )
      (map-set delegate-index { delegate: to } { last-idx: cur-idx })
      (print {
        event: "delegated",
        delegator: tx-sender,
        to: to,
        idx: cur-idx,
      })
    )
    (ok "delegated")
  )
)

;; reveal: reveal on behalf of 'voter'. Caller must be voter or registered delegate.
(define-public (reveal
    (poll-id uint)
    (preimage (buff 32))
    (choice bool)
    (voter principal)
  )
  (let (
      (popt (map-get? polls { id: poll-id }))
      (now stacks-block-height)
    )
    (match popt
      p (begin
        (asserts! (and (> now (get commit-end p)) (<= now (get reveal-end p)))
          ERR_PHASE
        )
        ;; O(1) fetch the committed hash for voter
        (match (map-get? commits-by-voter {
          poll-id: poll-id,
          voter: voter,
        })
          cby (let (
              (committed-hash (get hash cby))
              (computed (sha256 preimage))
            )
            (asserts! (is-eq computed committed-hash) ERR_HASH_MISMATCH)
            ;; ensure reveal not already done for voter
            (match (map-get? reveals {
              poll-id: poll-id,
              voter: voter,
            })
              existing-reveal
              ERR_ALREADY_REVEALED (begin
                ;; ensure caller is either voter or delegate for voter
                (let ((is-delegate (match (map-get? delegation { delegator: voter })
                    drec (is-eq (get delegate drec) tx-sender)
                    false
                  )))
                  (asserts! (or (is-eq tx-sender voter) is-delegate)
                    ERR_NO_RIGHTS
                  )
                  ;; tally
                  (if choice
                    (map-set polls { id: poll-id }
                      (merge p { yes: (+ (get yes p) u1) })
                    )
                    (map-set polls { id: poll-id }
                      (merge p { no: (+ (get no p) u1) })
                    )
                  )
                  (map-set reveals {
                    poll-id: poll-id,
                    voter: voter,
                  } {
                    revealed: true,
                    choice: choice,
                  })
                  (print {
                    event: "revealed",
                    poll: poll-id,
                    voter: voter,
                    by: tx-sender,
                    choice: choice,
                  })
                  (ok "revealed")
                )
              )
            )
          )
          ERR_NO_COMMIT
        )
      )
      ERR_INVALID_POLL
    )
  )
)

;; finalize poll: enforce quorum and set status
(define-public (finalize (poll-id uint))
  (let ((popt (map-get? polls { id: poll-id })))
    (match popt
      p (let ((now stacks-block-height))
        (asserts! (> now (get reveal-end p)) ERR_PHASE)
        (let (
            (yes (get yes p))
            (no (get no p))
            (q (get quorum p))
          )
          (asserts! (>= (+ yes no) q) ERR_INVALID_PARAMS)
          (let ((passed (if (> yes no)
              true
              false
            )))
            (map-set polls { id: poll-id }
              (merge p { status: (if passed
                u1
                u2
              ) }
              ))
            (print {
              event: "finalized",
              poll: poll-id,
              passed: passed,
              yes: yes,
              no: no,
            })
            (ok (if passed
              "passed"
              "failed"
            ))
          )
        )
      )
      ERR_INVALID_POLL
    )
  )
)

;; read helpers
(define-read-only (get-poll (poll-id uint))
  (map-get? polls { id: poll-id })
)
(define-read-only (get-commit-entry
    (poll-id uint)
    (idx uint)
  )
  (map-get? commits {
    poll-id: poll-id,
    idx: idx,
  })
)
(define-read-only (get-commit-last-idx (poll-id uint))
  (map-get? commit-index { poll-id: poll-id })
)
(define-read-only (get-reveal
    (poll-id uint)
    (voter principal)
  )
  (map-get? reveals {
    poll-id: poll-id,
    voter: voter,
  })
)
(define-read-only (get-delegation (delegator principal))
  (map-get? delegation { delegator: delegator })
)
(define-read-only (get-delegate-last-idx (delegate principal))
  (map-get? delegate-index { delegate: delegate })
)
(define-read-only (get-commit-by-voter
    (poll-id uint)
    (voter principal)
  )
  (map-get? commits-by-voter {
    poll-id: poll-id,
    voter: voter,
  })
)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; 
;; End CommitPool.clar (patched - Clarity v1 compatible)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; 
