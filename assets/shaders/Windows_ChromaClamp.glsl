//!HOOK CHROMA
//!BIND HOOKED
//!BIND LUMA
//!WHEN LUMA.w NATIVE_CROPPED.w > LUMA.h NATIVE_CROPPED.h > +
//!DESC Clamp padded decoder chroma to visible texel centers

vec4 hook() {
    // ANGLE 的外部纹理包含解码器对齐行；硬件 CLAMP_TO_EDGE 只钳制物理边界。
    // 先换回源纹理方向，再按实际子采样比例计算有效末端，兼容旋转和奇数尺寸。
    mat2 orientation = mat2(abs(LUMA_rot[0]), abs(LUMA_rot[1]));
    vec2 visible = ceil((orientation * (tex_offset + input_size)) * HOOKED_size / LUMA_size);
    vec2 upper = (min(visible, HOOKED_size) - vec2(0.5)) * HOOKED_pt;
    return HOOKED_tex(clamp(HOOKED_pos, 0.5 * HOOKED_pt, upper));
}
