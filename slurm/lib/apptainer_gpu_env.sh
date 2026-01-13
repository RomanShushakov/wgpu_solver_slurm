# Returns the host dir containing libGLX_nvidia.so.0
detect_nvidia_libdir() {
  local p
  p="$(ldconfig -p 2>/dev/null | awk '/libGLX_nvidia\.so\.0/ {print $NF; exit}')"
  if [[ -n "$p" && -e "$p" ]]; then
    dirname "$p"
  else
    echo "/lib/x86_64-linux-gnu"
  fi
}

build_gpu_binds() {
  local binds=()

  # Bind the NVIDIA Vulkan ICD json directory
  [[ -d /etc/vulkan ]]      && binds+=(--bind /etc/vulkan:/etc/vulkan)

  # GLVND vendor json (egl_vendor.d) lives here on your host
  [[ -d /usr/share/glvnd ]] && binds+=(--bind /usr/share/glvnd:/usr/share/glvnd)

  # Critical: host dir that contains libGLX_nvidia.so.0
  local nlib
  nlib="$(detect_nvidia_libdir)"
  [[ -d "$nlib" ]] && binds+=(--bind "$nlib:$nlib")

  printf '%s\n' "${binds[@]}"
}

print_gpu_env_exports() {
  local nlib
  nlib="$(detect_nvidia_libdir)"
  cat <<EOF
export WGPU_BACKEND=vulkan
export VK_ICD_FILENAMES=/etc/vulkan/icd.d/nvidia_icd.json
export LD_LIBRARY_PATH=$nlib:/.singularity.d/libs:\${LD_LIBRARY_PATH:-}
EOF
}
