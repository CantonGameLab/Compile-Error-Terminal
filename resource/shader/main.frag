#version 440 core
// 主着色器:图集 R8 灰度 → alpha;颜色纯由顶点色给出。
// 字形混合使用 DirectWrite 同源 gamma 校正(公式对照 reference/terminal
// src/renderer/atlas/dwrite_helpers.hlsl 的 DWrite_GrayscaleBlend:
// gamma=1.8 默认 gammaRatios + enhancedContrast=0.5,WT 细字体对比度增强):
// 笔画边缘 alpha 被提升,观感与 WT 一致(线性混合显细/淡)。
// 纯色矩形(白纹 tex=1)恒等,不受影响。
in vec2 vUv;
in vec4 vColor;
uniform sampler2D uTex;
out vec4 fragColor;

// DWrite gamma 1.8 gammaRatios 默认值(hlsl 注释原值)
const vec4 GAMMA_RATIOS = vec4(0.148054421, -0.894594550, 1.47590804, -0.324668258);
const float ENHANCED_CONTRAST = 0.5; // ClearType 路径默认

// 前景亮度(与 DWrite_CalcColorIntensity 一致)
float colorIntensity(vec3 c) {
	return dot(c, vec3(0.25, 0.5, 0.25));
}

// 对比度增强:alpha*(k+1)/(alpha*k+1)(DWrite_EnhanceContrast)
float enhanceContrast(float a, float k) {
	return a * (k + 1.0) / (a * k + 1.0);
}

// alpha 伽马校正:a + a(1-a)((g.x*f + g.y)a + (g.z*f + g.w))(DWrite_ApplyAlphaCorrection)
float applyAlphaCorrection(float a, float f, vec4 g) {
	return a + a * (1.0 - a) * ((g.x * f + g.y) * a + (g.z * f + g.w));
}

void main() {
	float glyphAlpha = texture(uTex, vUv).r;
	float a = clamp(vColor.a * glyphAlpha, 0.0, 1.0);
	float intensity = colorIntensity(vColor.rgb);
	float contrasted = enhanceContrast(a, ENHANCED_CONTRAST);
	float corrected = applyAlphaCorrection(contrasted, intensity, GAMMA_RATIOS);
	fragColor = vec4(vColor.rgb, corrected);
}
