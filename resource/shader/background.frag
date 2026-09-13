// 柔和流动背景(单色源):底色即色相源 —— 慢速 domain-warp 噪声驱动
// 小幅色相漂移(±40°)与亮度呼吸(±10%),低饱和基调保持;
// 强度 0.2..0.4 注入,主体始终是底色。无跳变,整体连续。
// 输入 = 终端背景纹理(theme 打底 + 全部 cell 底色),输出 = 最终背景色。
#version 440 core
in vec2 vUv;
uniform sampler2D uBg;
uniform vec2 uScreenSize;
uniform float uTime;
out vec4 fragColor;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// 平滑 value noise(值域 0..1)
float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
        mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x),
        u.y);
}

vec3 rgb2hsv(vec3 c) {
    vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
    vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
    vec3 p = abs(fract(c.xxx + vec3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return c.z * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

void main() {
    // vec4 base = texture(uBg, vUv);
    // float t = uTime * 0.35; // 慢速

    // // 慢速流动坐标(大尺度 domain warp)
    // vec2 p = vUv * 2.5;
    // vec2 q = vec2(
    //     noise(p + vec2(0.0, t)),
    //     noise(p + vec2(5.2, 1.3) - t * 0.55)
    // );
    // vec2 r = vec2(
    //     noise(p + 3.0 * q + vec2(1.7, 9.2)),
    //     noise(p + 3.0 * q + vec2(8.3, 2.8))
    // );

    // // 单色源:底色色相为基础,小幅漂移 + 亮度呼吸(低饱和维持)
    // vec3 hsv = rgb2hsv(base.rgb);
    // float hue = hsv.x + (r.x - 0.5) * 0.22;                 // ±~40°
    // float sat = hsv.y * 0.85 + 0.15;                        // 低饱和基调
    // float val = hsv.z * (0.95 + 0.10 * (r.y - 0.5) * 2.0);  // 亮度 ±10% 呼吸
    // vec3 tint = hsv2rgb(vec3(fract(hue), sat, val));

    // // 柔和注入:主体 = 底色,注入率随流动缓慢呼吸(0.2..0.4)
    // float mix_f = 0.30 + 0.10 * (q.x - 0.5) * 2.0;
    // vec3 out_c = mix(base.rgb, tint, clamp(mix_f, 0.0, 1.0)); 

    // fragColor = vec4(out_c, base.a);

	fragColor = texture(uBg, vUv);
}
