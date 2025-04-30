;; ChimeNest Sleep Tracker Smart Contract
;; This contract manages user sleep data, sound preferences, and alarm settings for the ChimeNest platform.
;; It securely stores sleep metrics, handles premium sound pack ownership, and facilitates smart alarms
;; while implementing a reward system for healthy sleep patterns.

;; Error Constants
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-USER-NOT-FOUND (err u101))
(define-constant ERR-INVALID-PARAMS (err u102))
(define-constant ERR-SOUND-PACK-NOT-FOUND (err u103))
(define-constant ERR-SOUND-PACK-ALREADY-OWNED (err u104))
(define-constant ERR-INSUFFICIENT-FUNDS (err u105))
(define-constant ERR-INVALID-SLEEP-DATA (err u106))
(define-constant ERR-ALARM-NOT-FOUND (err u107))
(define-constant ERR-DATA-SHARING-ALREADY-SET (err u108))
(define-constant ERR-REWARD-ALREADY-CLAIMED (err u109))

;; Data Space Definitions

;; User profile information
(define-map users 
  { user: principal }
  {
    registered-at: uint,
    total-sleep-sessions: uint,
    rewards-earned: uint,
    data-sharing-enabled: bool
  }
)

;; Encrypted sleep data that only the user can access
(define-map sleep-sessions
  { user: principal, session-id: uint }
  {
    date: uint,
    start-time: uint,
    end-time: uint,
    quality-score: uint,
    encrypted-metrics: (string-utf8 1024),
    reward-claimed: bool
  }
)

;; Available sound packs in the platform
(define-map sound-packs
  { sound-pack-id: uint }
  {
    name: (string-utf8 64),
    description: (string-utf8 256),
    price: uint,
    creator: principal,
    total-supply: uint,
    available-supply: uint
  }
)

;; User ownership of sound packs
(define-map sound-pack-ownership
  { user: principal, sound-pack-id: uint }
  { owned: bool }
)

;; User alarm preferences
(define-map alarm-settings
  { user: principal, alarm-id: uint }
  {
    sound-pack-id: uint,
    scheduled-time: uint,
    window-before: uint,
    window-after: uint,
    days-active: (list 7 bool),
    enabled: bool
  }
)

;; Global variables
(define-data-var admin principal tx-sender)
(define-data-var next-sound-pack-id uint u1)
(define-data-var reward-per-night uint u10) ;; Base reward tokens per night of good sleep
(define-data-var min-sleep-for-reward uint u21600) ;; 6 hours in seconds
(define-data-var data-sharing-bonus uint u5) ;; Additional reward for users who share data

;; Private Functions

;; Check if the user exists
(define-private (is-user-registered (user principal))
  (default-to false (get-user-info-exists user))
)

;; Get user info with existence check
(define-private (get-user-info-exists (user principal))
  (map-get? users { user: user })
)

;; Check if caller is admin
(define-private (is-admin)
  (is-eq tx-sender (var-get admin))
)

;; Calculate sleep duration in seconds
(define-private (calculate-sleep-duration (start-time uint) (end-time uint))
  (if (> end-time start-time)
    (- end-time start-time)
    u0)
)

;; Calculate sleep reward based on duration and quality
(define-private (calculate-sleep-reward (duration uint) (quality uint))
  (if (< duration (var-get min-sleep-for-reward))
    u0 ;; No reward if sleep duration is less than minimum
    (let 
      (
        (base-reward (var-get reward-per-night))
        (quality-factor (/ (* quality u100) u10000)) ;; Convert quality (0-100) to a 0-1 factor
      )
      (* base-reward quality-factor)
    )
  )
)

;; Add data sharing bonus if enabled
(define-private (add-data-sharing-bonus (user principal) (reward uint))
  (let
    (
      (user-data (unwrap! (get-user-info-exists user) reward))
      (data-sharing-enabled (get data-sharing-enabled user-data))
    )
    (if data-sharing-enabled
      (+ reward (var-get data-sharing-bonus))
      reward
    )
  )
)

;; Read-Only Functions

;; Get user profile information
(define-read-only (get-user-info (user principal))
  (ok (unwrap! (get-user-info-exists user) ERR-USER-NOT-FOUND))
)

;; Get user's sleep session information
(define-read-only (get-sleep-session (user principal) (session-id uint))
  (ok (unwrap! (map-get? sleep-sessions { user: user, session-id: session-id }) ERR-USER-NOT-FOUND))
)

;; Get sound pack details
(define-read-only (get-sound-pack (sound-pack-id uint))
  (ok (unwrap! (map-get? sound-packs { sound-pack-id: sound-pack-id }) ERR-SOUND-PACK-NOT-FOUND))
)

;; Check if user owns a specific sound pack
(define-read-only (has-sound-pack (user principal) (sound-pack-id uint))
  (default-to false (get owned (map-get? sound-pack-ownership { user: user, sound-pack-id: sound-pack-id })))
)

;; Get user's alarm settings
(define-read-only (get-alarm-settings (user principal) (alarm-id uint))
  (ok (unwrap! (map-get? alarm-settings { user: user, alarm-id: alarm-id }) ERR-ALARM-NOT-FOUND))
)

;; Get all alarms for a user
(define-read-only (get-all-alarms (user principal))
  (ok (map-get? alarm-settings { user: user, alarm-id: u0 }))
)

;; Public Functions

;; Register a new user
(define-public (register-user)
  (let
    ((user tx-sender))
    (if (is-user-registered user)
      ERR-USER-NOT-FOUND
      (begin
        (map-set users
          { user: user }
          {
            registered-at: block-height,
            total-sleep-sessions: u0,
            rewards-earned: u0,
            data-sharing-enabled: false
          }
        )
        (ok true)
      )
    )
  )
)

;; Record a new sleep session
(define-public (record-sleep-session 
  (start-time uint) 
  (end-time uint) 
  (quality-score uint) 
  (encrypted-metrics (string-utf8 1024)))
  
  (let
    (
      (user tx-sender)
      (user-data (unwrap! (get-user-info-exists user) ERR-USER-NOT-FOUND))
      (session-id (get total-sleep-sessions user-data))
      (new-session-count (+ session-id u1))
    )
    
    ;; Validate input parameters
    (asserts! (< start-time end-time) ERR-INVALID-PARAMS)
    (asserts! (<= quality-score u100) ERR-INVALID-PARAMS)
    
    ;; Store sleep session data
    (map-set sleep-sessions
      { user: user, session-id: session-id }
      {
        date: block-height,
        start-time: start-time,
        end-time: end-time,
        quality-score: quality-score,
        encrypted-metrics: encrypted-metrics,
        reward-claimed: false
      }
    )
    
    ;; Update user profile with new session count
    (map-set users
      { user: user }
      (merge user-data { total-sleep-sessions: new-session-count })
    )
    
    (ok session-id)
  )
)

;; Claim rewards for a sleep session
(define-public (claim-sleep-reward (session-id uint))
  (let
    (
      (user tx-sender)
      (session (unwrap! (map-get? sleep-sessions { user: user, session-id: session-id }) ERR-USER-NOT-FOUND))
      (user-data (unwrap! (get-user-info-exists user) ERR-USER-NOT-FOUND))
    )
    
    ;; Verify reward hasn't been claimed yet
    (asserts! (not (get reward-claimed session)) ERR-REWARD-ALREADY-CLAIMED)
    
    ;; Calculate the reward
    (let
      (
        (duration (calculate-sleep-duration (get start-time session) (get end-time session)))
        (quality (get quality-score session))
        (base-reward (calculate-sleep-reward duration quality))
        (reward (add-data-sharing-bonus user base-reward))
        (total-rewards-earned (+ (get rewards-earned user-data) reward))
      )
      
      ;; Update session to mark reward as claimed
      (map-set sleep-sessions
        { user: user, session-id: session-id }
        (merge session { reward-claimed: true })
      )
      
      ;; Update user's total rewards earned
      (map-set users
        { user: user }
        (merge user-data { rewards-earned: total-rewards-earned })
      )
      
      (ok reward)
    )
  )
)

;; Opt-in or opt-out of data sharing
(define-public (set-data-sharing (enabled bool))
  (let
    (
      (user tx-sender)
      (user-data (unwrap! (get-user-info-exists user) ERR-USER-NOT-FOUND))
    )
    
    (map-set users
      { user: user }
      (merge user-data { data-sharing-enabled: enabled })
    )
    
    (ok true)
  )
)

;; Create a new sound pack (admin only)
(define-public (create-sound-pack 
  (name (string-utf8 64)) 
  (description (string-utf8 256)) 
  (price uint) 
  (total-supply uint))
  
  (begin
    ;; Check caller is admin
    (asserts! (is-admin) ERR-NOT-AUTHORIZED)
    
    (let
      ((sound-pack-id (var-get next-sound-pack-id)))
      
      ;; Create the sound pack
      (map-set sound-packs
        { sound-pack-id: sound-pack-id }
        {
          name: name,
          description: description,
          price: price,
          creator: tx-sender,
          total-supply: total-supply,
          available-supply: total-supply
        }
      )
      
      ;; Increment the sound pack ID counter
      (var-set next-sound-pack-id (+ sound-pack-id u1))
      
      (ok sound-pack-id)
    )
  )
)

;; Purchase a sound pack
(define-public (purchase-sound-pack (sound-pack-id uint))
  (let
    (
      (user tx-sender)
      (sound-pack (unwrap! (map-get? sound-packs { sound-pack-id: sound-pack-id }) ERR-SOUND-PACK-NOT-FOUND))
      (user-data (unwrap! (get-user-info-exists user) ERR-USER-NOT-FOUND))
    )
    
    ;; Check if user already owns this sound pack
    (asserts! (not (has-sound-pack user sound-pack-id)) ERR-SOUND-PACK-ALREADY-OWNED)
    
    ;; Check if there's available supply
    (asserts! (> (get available-supply sound-pack) u0) ERR-SOUND-PACK-NOT-FOUND)
    
    ;; Check if user has enough rewards to purchase
    (asserts! (>= (get rewards-earned user-data) (get price sound-pack)) ERR-INSUFFICIENT-FUNDS)
    
    ;; Update user's reward balance
    (map-set users
      { user: user }
      (merge user-data { rewards-earned: (- (get rewards-earned user-data) (get price sound-pack)) })
    )
    
    ;; Grant ownership of sound pack to user
    (map-set sound-pack-ownership
      { user: user, sound-pack-id: sound-pack-id }
      { owned: true }
    )
    
    ;; Update available supply
    (map-set sound-packs
      { sound-pack-id: sound-pack-id }
      (merge sound-pack { available-supply: (- (get available-supply sound-pack) u1) })
    )
    
    (ok true)
  )
)

;; Set or update an alarm
(define-public (set-alarm 
  (alarm-id uint) 
  (sound-pack-id uint) 
  (scheduled-time uint) 
  (window-before uint) 
  (window-after uint) 
  (days-active (list 7 bool)))
  
  (let
    (
      (user tx-sender)
    )
    
    ;; Ensure user is registered
    (asserts! (is-user-registered user) ERR-USER-NOT-FOUND)
    
    ;; Validate sound pack ownership
    (asserts! (has-sound-pack user sound-pack-id) ERR-SOUND-PACK-NOT-FOUND)
    
    ;; Set the alarm
    (map-set alarm-settings
      { user: user, alarm-id: alarm-id }
      {
        sound-pack-id: sound-pack-id,
        scheduled-time: scheduled-time,
        window-before: window-before,
        window-after: window-after,
        days-active: days-active,
        enabled: true
      }
    )
    
    (ok true)
  )
)

;; Enable or disable an alarm
(define-public (toggle-alarm (alarm-id uint) (enabled bool))
  (let
    (
      (user tx-sender)
      (alarm (unwrap! (map-get? alarm-settings { user: user, alarm-id: alarm-id }) ERR-ALARM-NOT-FOUND))
    )
    
    (map-set alarm-settings
      { user: user, alarm-id: alarm-id }
      (merge alarm { enabled: enabled })
    )
    
    (ok true)
  )
)

;; Update admin (only current admin can call)
(define-public (set-admin (new-admin principal))
  (begin
    (asserts! (is-admin) ERR-NOT-AUTHORIZED)
    (var-set admin new-admin)
    (ok true)
  )
)

;; Update reward parameters (admin only)
(define-public (update-reward-parameters 
  (new-reward-per-night uint) 
  (new-min-sleep uint) 
  (new-data-sharing-bonus uint))
  
  (begin
    (asserts! (is-admin) ERR-NOT-AUTHORIZED)
    (var-set reward-per-night new-reward-per-night)
    (var-set min-sleep-for-reward new-min-sleep)
    (var-set data-sharing-bonus new-data-sharing-bonus)
    (ok true)
  )
)