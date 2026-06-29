FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies and Intel GPU compute runtime for Panther Lake
RUN apt-get update -qq && \
    apt-get install -y -qq wget curl software-properties-common python3 python3-pip python3-venv && \
    add-apt-repository -y ppa:kobuk-team/intel-graphics && \
    apt-get update -qq && \
    apt-get install -y -qq intel-opencl-icd libze-intel-gpu1 libze1 && \
    rm -rf /var/lib/apt/lists/*

# Install OpenVINO and Python packages via pip (no bundled GPU plugin to conflict)
RUN pip3 install --break-system-packages --no-cache-dir \
    openvino==2026.0.0 \
    openvino-genai \
    "optimum[openvino]" \
    datasets

# Install Intel NPU driver (user-space components)
RUN wget -q https://github.com/intel/linux-npu-driver/releases/download/v1.30.0/linux-npu-driver-v1.30.0.20260311-22963593310-ubuntu2404.tar.gz && \
    tar -xf linux-npu-driver-v1.30.0*.tar.gz && \
    (dpkg -i *.deb || (apt-get update -qq && apt-get install -f -y -qq)) && \
    rm -f *.deb *.tar.gz && \
    rm -rf /var/lib/apt/lists/*

# Download and export model
# Use a pre-exported NPU-optimized model from Hugging Face
# Alternative: export your own with:
#   optimum-cli export openvino -m Qwen/Qwen2-0.5B-Instruct \
#     --weight-format int4 --sym --ratio 1.0 --group-size 128 /models/qwen2-npu
ARG MODEL_ID=OpenVINO/TinyLlama-1.1B-Chat-v1.0-int4-ov
ARG MODEL_DIR=/models/tinyllama-npu
RUN huggingface-cli download ${MODEL_ID} --local-dir ${MODEL_DIR}

# Copy chatbot script (last -- changes most often)
COPY npu-chatbot.py /app/npu-chatbot.py

WORKDIR /app
ENTRYPOINT ["python3", "/app/npu-chatbot.py"]
CMD ["--model", "/models/tinyllama-npu", "--device", "NPU"]
