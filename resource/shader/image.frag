#version 440 core
// 图像渲染:RGBA8 纹理直出(与主 shader 的 R8 灰度字形路径分离)。
// 混合 = 全局 SRC_ALPHA(纹理为直通 alpha),颜色纯由纹理给出。
in vec2 vUv;
in vec4 vColor;
uniform sampler2D uTex;
out vec4 fragColor;
void main() {
    vec4 t = texture(uTex, vUv);
    fragColor = vec4(t.rgb * vColor.rgb, t.a * vColor.a);
}
