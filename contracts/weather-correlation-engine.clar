;; weather-correlation-engine
;; Weather data correlation to determine if delays are weather-related

;; constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u2001))
(define-constant ERR_WEATHER_NOT_FOUND (err u2002))
(define-constant ERR_INVALID_WEATHER_DATA (err u2003))
(define-constant ERR_AIRPORT_NOT_FOUND (err u2004))
(define-constant ERR_INVALID_CORRELATION_DATA (err u2005))
(define-constant ERR_ORACLE_NOT_REGISTERED (err u2006))
(define-constant ERR_INSUFFICIENT_DATA (err u2007))

;; Weather severity codes
(define-constant WEATHER_CLEAR u0)
(define-constant WEATHER_LIGHT u1)
(define-constant WEATHER_MODERATE u2)
(define-constant WEATHER_SEVERE u3)
(define-constant WEATHER_EXTREME u4)

;; Weather type codes
(define-constant WEATHER_TYPE_CLEAR u0)
(define-constant WEATHER_TYPE_RAIN u1)
(define-constant WEATHER_TYPE_SNOW u2)
(define-constant WEATHER_TYPE_FOG u3)
(define-constant WEATHER_TYPE_WIND u4)
(define-constant WEATHER_TYPE_STORM u5)
(define-constant WEATHER_TYPE_ICE u6)

;; data maps and vars
(define-map weather-data
  { airport-code: (string-ascii 5), timestamp: uint }
  {
    temperature: int,
    visibility: uint,
    wind-speed: uint,
    wind-direction: uint,
    precipitation: uint,
    weather-type: uint,
    severity: uint,
    pressure: uint,
    humidity: uint,
    reporter: principal,
    last-updated: uint,
    confirmations: uint
  }
)

(define-map airport-profiles
  { airport-code: (string-ascii 5) }
  {
    latitude: int,
    longitude: int,
    elevation: uint,
    timezone-offset: int,
    weather-sensitivity: uint,
    historical-delay-factor: uint,
    is-active: bool
  }
)

(define-map weather-correlations
  { correlation-id: uint }
  {
    airport-code: (string-ascii 5),
    timestamp: uint,
    weather-type: uint,
    severity: uint,
    delay-probability: uint,
    average-delay-minutes: uint,
    confidence-score: uint,
    sample-size: uint,
    created-by: principal
  }
)

(define-map authorized-weather-oracles
  { oracle: principal }
  {
    is-authorized: bool,
    specialization: uint,
    accuracy-score: uint,
    total-reports: uint,
    registration-block: uint
  }
)

(define-map delay-assessments
  { assessment-id: uint }
  {
    airport-code: (string-ascii 5),
    timestamp: uint,
    weather-factor: uint,
    non-weather-factor: uint,
    total-delay-minutes: uint,
    weather-caused-delay: uint,
    confidence-level: uint,
    assessor: principal
  }
)

(define-data-var next-correlation-id uint u0)
(define-data-var next-assessment-id uint u0)
(define-data-var min-sample-size uint u10)
(define-data-var contract-paused bool false)
(define-data-var registered-oracle-count uint u0)

;; private functions
(define-private (min-uint (a uint) (b uint))
  (if (<= a b) a b))

(define-private (is-authorized-weather-oracle (oracle principal))
  (default-to false
    (get is-authorized (map-get? authorized-weather-oracles { oracle: oracle }))))

(define-private (is-valid-weather-type (weather-type uint))
  (and (>= weather-type WEATHER_TYPE_CLEAR) (<= weather-type WEATHER_TYPE_ICE)))

(define-private (is-valid-severity (severity uint))
  (and (>= severity WEATHER_CLEAR) (<= severity WEATHER_EXTREME)))

(define-private (calculate-delay-probability (weather-type uint) (severity uint) (airport-code (string-ascii 5)))
  (let (
    (airport-data (map-get? airport-profiles { airport-code: airport-code }))
    (sensitivity (if (is-some airport-data)
                  (get weather-sensitivity (unwrap-panic airport-data))
                  u50))
    (base-probability (if (is-eq weather-type WEATHER_TYPE_CLEAR)
                       u5
                       (if (is-eq weather-type WEATHER_TYPE_RAIN)
                         (* u15 severity)
                         (if (is-eq weather-type WEATHER_TYPE_SNOW)
                           (* u25 severity)
                           (if (is-eq weather-type WEATHER_TYPE_FOG)
                             (* u20 severity)
                             (if (is-eq weather-type WEATHER_TYPE_WIND)
                               (* u18 severity)
                               (if (is-eq weather-type WEATHER_TYPE_STORM)
                                 (* u35 severity)
                                 (if (is-eq weather-type WEATHER_TYPE_ICE)
                                   (* u40 severity)
                                   u10))))))))
  )
    (min-uint u95 (* base-probability (/ (+ sensitivity u50) u100)))))

(define-private (assess-weather-impact (weather-severity uint) (weather-type uint) (total-delay uint))
  (let (
    (weather-impact-factor (if (is-eq weather-type WEATHER_TYPE_CLEAR)
                            u0
                            (if (is-eq weather-type WEATHER_TYPE_RAIN)
                              (* weather-severity u15)
                              (if (is-eq weather-type WEATHER_TYPE_SNOW)
                                (* weather-severity u25)
                                (if (is-eq weather-type WEATHER_TYPE_FOG)
                                  (* weather-severity u20)
                                  (if (is-eq weather-type WEATHER_TYPE_WIND)
                                    (* weather-severity u18)
                                    (if (is-eq weather-type WEATHER_TYPE_STORM)
                                      (* weather-severity u35)
                                      (if (is-eq weather-type WEATHER_TYPE_ICE)
                                        (* weather-severity u30)
                                        u5))))))))
    (weather-delay (/ (* total-delay weather-impact-factor) u100))
  )
    (min-uint total-delay weather-delay)))

(define-private (update-oracle-accuracy (oracle principal) (accuracy-boost uint))
  (let (
    (oracle-data (unwrap! (map-get? authorized-weather-oracles { oracle: oracle }) false))
    (current-score (get accuracy-score oracle-data))
    (total-reports (get total-reports oracle-data))
    (new-total (+ total-reports u1))
    (new-score (/ (+ (* current-score total-reports) accuracy-boost) new-total))
  )
    (map-set authorized-weather-oracles
      { oracle: oracle }
      (merge oracle-data {
        accuracy-score: new-score,
        total-reports: new-total
      }))))

(define-private (validate-weather-data 
  (temperature int)
  (visibility uint)
  (wind-speed uint)
  (precipitation uint)
  (pressure uint)
  (humidity uint))
  (and
    (and (>= temperature -50) (<= temperature 60)) ;; Celsius range
    (<= visibility u50000) ;; Max 50km visibility
    (<= wind-speed u200) ;; Max 200 km/h wind
    (<= precipitation u1000) ;; Max 1000mm precipitation
    (and (>= pressure u800) (<= pressure u1200)) ;; Pressure in hPa
    (<= humidity u100))) ;; Humidity percentage

;; public functions
(define-public (register-weather-oracle (oracle principal) (specialization uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (asserts! (not (var-get contract-paused)) ERR_NOT_AUTHORIZED)
    (asserts! (<= specialization WEATHER_TYPE_ICE) ERR_INVALID_WEATHER_DATA)
    (map-set authorized-weather-oracles
      { oracle: oracle }
      {
        is-authorized: true,
        specialization: specialization,
        accuracy-score: u85,
        total-reports: u0,
        registration-block: stacks-block-height
      })
    (var-set registered-oracle-count (+ (var-get registered-oracle-count) u1))
    (print { event: "weather-oracle-registered", oracle: oracle, specialization: specialization })
    (ok true)))

(define-public (register-airport-profile
  (airport-code (string-ascii 5))
  (latitude int)
  (longitude int)
  (elevation uint)
  (timezone-offset int)
  (weather-sensitivity uint))
  (begin
    (asserts! (is-authorized-weather-oracle tx-sender) ERR_ORACLE_NOT_REGISTERED)
    (asserts! (not (var-get contract-paused)) ERR_NOT_AUTHORIZED)
    (asserts! (> (len airport-code) u2) ERR_INVALID_WEATHER_DATA)
    (asserts! (<= weather-sensitivity u100) ERR_INVALID_WEATHER_DATA)
    (map-set airport-profiles
      { airport-code: airport-code }
      {
        latitude: latitude,
        longitude: longitude,
        elevation: elevation,
        timezone-offset: timezone-offset,
        weather-sensitivity: weather-sensitivity,
        historical-delay-factor: u50,
        is-active: true
      })
    (print { event: "airport-profile-registered", airport-code: airport-code })
    (ok true)))

(define-public (report-weather-data
  (airport-code (string-ascii 5))
  (temperature int)
  (visibility uint)
  (wind-speed uint)
  (wind-direction uint)
  (precipitation uint)
  (weather-type uint)
  (severity uint)
  (pressure uint)
  (humidity uint))
  (let (
    (timestamp stacks-block-height)
  )
    (asserts! (is-authorized-weather-oracle tx-sender) ERR_ORACLE_NOT_REGISTERED)
    (asserts! (not (var-get contract-paused)) ERR_NOT_AUTHORIZED)
    (asserts! (is-some (map-get? airport-profiles { airport-code: airport-code })) ERR_AIRPORT_NOT_FOUND)
    (asserts! (is-valid-weather-type weather-type) ERR_INVALID_WEATHER_DATA)
    (asserts! (is-valid-severity severity) ERR_INVALID_WEATHER_DATA)
    (asserts! (validate-weather-data temperature visibility wind-speed precipitation pressure humidity) ERR_INVALID_WEATHER_DATA)
    (map-set weather-data
      { airport-code: airport-code, timestamp: timestamp }
      {
        temperature: temperature,
        visibility: visibility,
        wind-speed: wind-speed,
        wind-direction: wind-direction,
        precipitation: precipitation,
        weather-type: weather-type,
        severity: severity,
        pressure: pressure,
        humidity: humidity,
        reporter: tx-sender,
        last-updated: timestamp,
        confirmations: u1
      })
    (update-oracle-accuracy tx-sender u5)
    (print {
      event: "weather-data-reported",
      airport-code: airport-code,
      weather-type: weather-type,
      severity: severity,
      reporter: tx-sender
    })
    (ok true)))

(define-public (create-weather-correlation
  (airport-code (string-ascii 5))
  (weather-type uint)
  (severity uint)
  (delay-probability uint)
  (average-delay-minutes uint)
  (sample-size uint))
  (let (
    (correlation-id (var-get next-correlation-id))
    (confidence-score (if (>= sample-size (var-get min-sample-size))
                      (min-uint u95 (+ u60 (/ (* sample-size u35) u100)))
                      u30))
  )
    (asserts! (is-authorized-weather-oracle tx-sender) ERR_ORACLE_NOT_REGISTERED)
    (asserts! (not (var-get contract-paused)) ERR_NOT_AUTHORIZED)
    (asserts! (is-some (map-get? airport-profiles { airport-code: airport-code })) ERR_AIRPORT_NOT_FOUND)
    (asserts! (is-valid-weather-type weather-type) ERR_INVALID_WEATHER_DATA)
    (asserts! (is-valid-severity severity) ERR_INVALID_WEATHER_DATA)
    (asserts! (<= delay-probability u100) ERR_INVALID_CORRELATION_DATA)
    (asserts! (> sample-size u0) ERR_INSUFFICIENT_DATA)
    (map-set weather-correlations
      { correlation-id: correlation-id }
      {
        airport-code: airport-code,
        timestamp: stacks-block-height,
        weather-type: weather-type,
        severity: severity,
        delay-probability: delay-probability,
        average-delay-minutes: average-delay-minutes,
        confidence-score: confidence-score,
        sample-size: sample-size,
        created-by: tx-sender
      })
    (var-set next-correlation-id (+ correlation-id u1))
    (update-oracle-accuracy tx-sender u10)
    (print {
      event: "weather-correlation-created",
      correlation-id: correlation-id,
      airport-code: airport-code,
      confidence: confidence-score
    })
    (ok correlation-id)))

(define-public (assess-delay-weather-factor
  (airport-code (string-ascii 5))
  (total-delay-minutes uint)
  (weather-type uint)
  (weather-severity uint))
  (let (
    (assessment-id (var-get next-assessment-id))
    (weather-caused-delay (assess-weather-impact weather-severity weather-type total-delay-minutes))
    (non-weather-delay (- total-delay-minutes weather-caused-delay))
    (weather-factor (if (> total-delay-minutes u0) (/ (* weather-caused-delay u100) total-delay-minutes) u0))
    (confidence-level (calculate-delay-probability weather-type weather-severity airport-code))
  )
    (asserts! (is-authorized-weather-oracle tx-sender) ERR_ORACLE_NOT_REGISTERED)
    (asserts! (not (var-get contract-paused)) ERR_NOT_AUTHORIZED)
    (asserts! (is-some (map-get? airport-profiles { airport-code: airport-code })) ERR_AIRPORT_NOT_FOUND)
    (asserts! (is-valid-weather-type weather-type) ERR_INVALID_WEATHER_DATA)
    (asserts! (is-valid-severity weather-severity) ERR_INVALID_WEATHER_DATA)
    (map-set delay-assessments
      { assessment-id: assessment-id }
      {
        airport-code: airport-code,
        timestamp: stacks-block-height,
        weather-factor: weather-factor,
        non-weather-factor: (- u100 weather-factor),
        total-delay-minutes: total-delay-minutes,
        weather-caused-delay: weather-caused-delay,
        confidence-level: confidence-level,
        assessor: tx-sender
      })
    (var-set next-assessment-id (+ assessment-id u1))
    (update-oracle-accuracy tx-sender u8)
    (print {
      event: "delay-assessment-created",
      assessment-id: assessment-id,
      weather-factor: weather-factor,
      confidence: confidence-level
    })
    (ok {
      assessment-id: assessment-id,
      weather-factor: weather-factor,
      weather-delay: weather-caused-delay,
      confidence: confidence-level
    })))

(define-public (emergency-pause)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (var-set contract-paused true)
    (print { event: "weather-contract-paused" })
    (ok true)))

(define-public (emergency-unpause)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (var-set contract-paused false)
    (print { event: "weather-contract-unpaused" })
    (ok true)))

;; Read-only functions
(define-read-only (get-weather-data (airport-code (string-ascii 5)) (timestamp uint))
  (map-get? weather-data { airport-code: airport-code, timestamp: timestamp }))

(define-read-only (get-airport-profile (airport-code (string-ascii 5)))
  (map-get? airport-profiles { airport-code: airport-code }))

(define-read-only (get-weather-correlation (correlation-id uint))
  (map-get? weather-correlations { correlation-id: correlation-id }))

(define-read-only (get-delay-assessment (assessment-id uint))
  (map-get? delay-assessments { assessment-id: assessment-id }))

(define-read-only (get-oracle-info (oracle principal))
  (map-get? authorized-weather-oracles { oracle: oracle }))

(define-read-only (predict-weather-delay (airport-code (string-ascii 5)) (weather-type uint) (severity uint))
  (let (
    (delay-probability (calculate-delay-probability weather-type severity airport-code))
    (estimated-delay (if (is-eq weather-type WEATHER_TYPE_CLEAR)
                      u0
                      (if (is-eq weather-type WEATHER_TYPE_RAIN)
                        (* severity u20)
                        (if (is-eq weather-type WEATHER_TYPE_SNOW)
                          (* severity u45)
                          (if (is-eq weather-type WEATHER_TYPE_FOG)
                            (* severity u35)
                            (if (is-eq weather-type WEATHER_TYPE_WIND)
                              (* severity u25)
                              (if (is-eq weather-type WEATHER_TYPE_STORM)
                                (* severity u60)
                                (if (is-eq weather-type WEATHER_TYPE_ICE)
                                  (* severity u50)
                                  u10))))))))
  )
    {
      delay-probability: delay-probability,
      estimated-delay-minutes: estimated-delay,
      weather-type: weather-type,
      severity: severity
    }))

(define-read-only (get-contract-stats)
  {
    oracle-count: (var-get registered-oracle-count),
    next-correlation-id: (var-get next-correlation-id),
    next-assessment-id: (var-get next-assessment-id),
    min-sample-size: (var-get min-sample-size),
    is-paused: (var-get contract-paused)
  })
