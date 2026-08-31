import Foundation

/// Known voices for Kokoro (the default mlx-audio TTS model), grouped by language.
enum KokoroVoices {
    static let groups: [(name: String, voices: [String])] = [
        ("American Female", ["af_heart", "af_alloy", "af_aoede", "af_bella", "af_jessica", "af_kore", "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky"]),
        ("American Male", ["am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael", "am_onyx", "am_puck", "am_santa"]),
        ("British Female", ["bf_alice", "bf_emma", "bf_isabella", "bf_lily"]),
        ("British Male", ["bm_daniel", "bm_fable", "bm_george", "bm_lewis"]),
        ("Japanese", ["jf_alpha", "jf_gongitsune", "jf_nezumi", "jf_tebukuro", "jm_kumo"]),
        ("Chinese", ["zf_xiaobei", "zf_xiaoni", "zf_xiaoxiao", "zf_xiaoyi", "zm_yunjian", "zm_yunxi", "zm_yunxia", "zm_yunyang"]),
        ("Other", ["ef_dora", "em_alex", "ff_siwis", "hf_alpha", "hf_beta", "hm_omega", "hm_psi", "if_sara", "im_nicola", "pf_dora", "pm_alex"])
    ]
}
