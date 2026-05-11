# Hướng dẫn chạy Pipecat Server trên VPS Windows 11

## Yêu cầu hệ thống

- Windows 11
- Python 3.10+ (https://www.python.org/downloads/)
- pip (đi kèm Python)
- ngrok (https://ngrok.com/download)
- Git (https://git-scm.com/download/win)

## Bước 1: Cài đặt Python và Git

### Cài Python

1. Tải Python 3.11+ từ https://www.python.org/downloads/
2. Chạy installer, **đánh dấu "Add Python to PATH"**
3. Kiểm tra:

```powershell
python --version
pip --version
```

### Cài Git

1. Tải Git từ https://git-scm.com/download/win
2. Chạy installer với mặc định
3. Kiểm tra:

```powershell
git --version
```

### Cài ngrok

1. Tải ngrok từ https://ngrok.com/download
2. Giải nén vào `C:\ngrok\`
3. Đăng ký và lấy authtoken tại https://dashboard.ngrok.com
4. Cấu hình:

```powershell
C:\ngrok\ngrok.exe config add-authtoken YOUR_AUTHTOKEN
```

## Bước 2: Clone Pipecat Repository

Mở PowerShell với quyền Administrator:

```powershell
cd C:\
git clone https://github.com/pipecat-ai/pipecat.git
cd C:\pipecat
```

## Bước 3: Tạo Python Virtual Environment

```powershell
python -m venv venv
.\venv\Scripts\Activate.ps1
```

Nếu bị lỗi execution policy:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

Sau đó chạy lại:

```powershell
.\venv\Scripts\Activate.ps1
```

## Bước 4: Cài đặt Pipecat

```powershell
pip install pipecat-ai[all]
pip install websockets uvicorn fastapi
```

## Bước 5: Tạo WebSocket Server

Tạo file `C:\pipecat\ws_server.py`:

```python
import asyncio
import json
import os
import logging
from typing import Optional
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
import uvicorn

# Pipecat imports
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.runner import PipelineRunner
from pipecat.pipeline.task import PipelineParams, PipelineTask
from pipecat.processors.frameworks.rtvi import RTVIProcessor

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def create_stt_service(provider: str, api_key: str):
    """Tạo STT service dựa trên provider"""
    if provider == "soniox":
        from pipecat.services.soniox import SonioxSTTService
        return SonioxSTTService(api_key=api_key)
    elif provider == "deepgram":
        from pipecat.services.deepgram import DeepgramSTTService
        return DeepgramSTTService(api_key=api_key)
    elif provider == "google":
        from pipecat.services.google import GoogleSTTService
        return GoogleSTTService(api_key=api_key)
    elif provider == "assemblyai":
        from pipecat.services.assemblyai import AssemblyAISTTService
        return AssemblyAISTTService(api_key=api_key)
    elif provider == "openai":
        from pipecat.services.openai import OpenAISTTService
        return OpenAISTTService(api_key=api_key)
    elif provider == "whisper":
        from pipecat.services.whisper import WhisperSTTService
        return WhisperSTTService(api_key=api_key)
    else:
        raise ValueError(f"Unsupported STT provider: {provider}")


def create_llm_service(provider: str, api_key: str, model: str):
    """Tạo LLM service dựa trên provider"""
    if provider == "openai":
        from pipecat.services.openai import OpenAILLMService
        return OpenAILLMService(api_key=api_key, model=model)
    elif provider == "anthropic":
        from pipecat.services.anthropic import AnthropicLLMService
        return AnthropicLLMService(api_key=api_key, model=model)
    elif provider == "google":
        from pipecat.services.google import GoogleLLMService
        return GoogleLLMService(api_key=api_key, model=model)
    elif provider == "groq":
        from pipecat.services.groq import GroqLLMService
        return GroqLLMService(api_key=api_key, model=model)
    elif provider == "mistral":
        from pipecat.services.mistral import MistralLLMService
        return MistralLLMService(api_key=api_key, model=model)
    else:
        raise ValueError(f"Unsupported LLM provider: {provider}")


def create_tts_service(provider: str, api_key: str):
    """Tạo TTS service dựa trên provider"""
    if provider == "soniox":
        from pipecat.services.soniox import SonioxTTSService
        return SonioxTTSService(api_key=api_key)
    elif provider == "cartesia":
        from pipecat.services.cartesia import CartesiaTTSService
        return CartesiaTTSService(api_key=api_key)
    elif provider == "elevenlabs":
        from pipecat.services.elevenlabs import ElevenLabsTTSService
        return ElevenLabsTTSService(api_key=api_key)
    elif provider == "openai":
        from pipecat.services.openai import OpenAITTSService
        return OpenAITTSService(api_key=api_key)
    elif provider == "deepgram":
        from pipecat.services.deepgram import DeepgramTTSService
        return DeepgramTTSService(api_key=api_key)
    elif provider == "google":
        from pipecat.services.google import GoogleTTSService
        return GoogleTTSService(api_key=api_key)
    else:
        raise ValueError(f"Unsupported TTS provider: {provider}")


class PipecatSession:
    """Quản lý một Pipecat session"""

    def __init__(self, websocket: WebSocket, config: dict):
        self.websocket = websocket
        self.config = config
        self.pipeline = None
        self.runner = None
        self.task = None

    async def start(self):
        """Khởi động pipeline"""
        try:
            processors = []

            # STT
            stt_config = self.config.get("stt")
            if stt_config:
                stt = create_stt_service(
                    stt_config["provider"],
                    stt_config["api_key"]
                )
                processors.append(stt)
                logger.info(f"STT: {stt_config['provider']}")

            # LLM
            llm_config = self.config.get("llm")
            if llm_config:
                llm = create_llm_service(
                    llm_config["provider"],
                    llm_config["api_key"],
                    llm_config["model"]
                )
                processors.append(llm)
                logger.info(f"LLM: {llm_config['provider']} - {llm_config['model']}")

            # TTS
            tts_config = self.config.get("tts")
            if tts_config:
                tts = create_tts_service(
                    tts_config["provider"],
                    tts_config["api_key"]
                )
                processors.append(tts)
                logger.info(f"TTS: {tts_config['provider']}")

            # RTVI Processor để gửi events về client
            rtvi = RTVIProcessor()
            processors.append(rtvi)

            # Tạo pipeline
            self.pipeline = Pipeline(processors)

            # Tạo task
            self.task = PipelineTask(
                self.pipeline,
                PipelineParams(
                    allow_interruptions=True,
                    enable_metrics=True,
                )
            )

            # Chạy pipeline
            self.runner = PipelineRunner()
            await self.runner.run(self.task)

        except Exception as e:
            logger.error(f"Pipeline error: {e}")
            await self.send_error(str(e))

    async def send_error(self, message: str):
        """Gửi lỗi về client"""
        await self.websocket.send_json({
            "type": "error",
            "data": {"message": message}
        })

    async def send_message(self, msg_type: str, data: dict):
        """Gửi message về client"""
        await self.websocket.send_json({
            "type": msg_type,
            "data": data
        })

    async def stop(self):
        """Dừng pipeline"""
        if self.task:
            self.task.cancel()
        if self.runner:
            self.runner.stop()


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    """WebSocket endpoint cho Flutter app"""
    await websocket.accept()
    session = None

    try:
        while True:
            data = await websocket.receive()

            if data.get("type") == "websocket.receive":
                # Text message (JSON config hoặc command)
                if "text" in data:
                    message = json.loads(data["text"])
                    msg_type = message.get("type")

                    if msg_type == "config":
                        # Nhận config từ Flutter app
                        config = message.get("data", {})
                        logger.info(f"Received config: {json.dumps(config, indent=2)}")

                        # Khởi tạo session với config
                        session = PipecatSession(websocket, config)
                        await session.start()

                        # Gửi xác nhận
                        await websocket.send_json({
                            "type": "connected",
                            "data": {"status": "ok"}
                        })

                    elif msg_type == "text":
                        # Text message từ user
                        text = message.get("data", {}).get("text", "")
                        logger.info(f"User text: {text}")
                        # Xử lý text message ở đây

                # Binary data (audio)
                elif "bytes" in data:
                    audio_data = data["bytes"]
                    # Gửi audio vào pipeline
                    if session and session.pipeline:
                        # Xử lý audio data
                        pass

    except WebSocketDisconnect:
        logger.info("Client disconnected")
    except Exception as e:
        logger.error(f"WebSocket error: {e}")
    finally:
        if session:
            await session.stop()


@app.get("/")
async def root():
    """Health check endpoint"""
    return {"status": "ok", "message": "Pipecat WebSocket Server"}


@app.get("/health")
async def health():
    """Health check endpoint"""
    return {"status": "healthy"}


if __name__ == "__main__":
    uvicorn.run(
        "ws_server:app",
        host="0.0.0.0",
        port=3000,
        reload=True,
        log_level="info"
    )
```

## Bước 6: Cấu hình Environment Variables

Tạo file `C:\pipecat\.env`:

```env
# Không cần set API keys ở server
# Vì Flutter app sẽ gửi API keys qua WebSocket config message
# Server chỉ cần cài đặt các Python packages

# Nếu muốn set default (optional):
# OPENAI_API_KEY=your_default_key
```

## Bước 7: Chạy Server

### Chạy trực tiếp

```powershell
cd C:\pipecat
.\venv\Scripts\Activate.ps1
python ws_server.py
```

Server sẽ chạy trên `http://localhost:3000`

### Chạy như Windows Service (tùy chọn)

Cài NSSM (Non-Sucking Service Manager):

```powershell
# Tải NSSM từ https://nssm.cc/download
# Giải nén vào C:\nssm\

# Tạo service
C:\nssm\win64\nssm.exe install PipecatServer "C:\Project\pipecat-main\venv\Scripts\python.exe" "C:\Project\pipecat-main\ws_server.py"
C:\nssm\win64\nssm.exe set PipecatServer AppDirectory "C:\Project\pipecat-main"
C:\nssm\win64\nssm.exe set PipecatServer DisplayName "Pipecat WebSocket Server"
C:\nssm\win64\nssm.exe set PipecatServer Description "Pipecat AI Translate Server"
C:\nssm\win64\nssm.exe set PipecatServer Start SERVICE_AUTO_START

# Khởi động service
C:\nssm\win64\nssm.exe start PipecatServer

# Kiểm tra status
C:\nssm\win64\nssm.exe status PipecatServer

# Xem logs
C:\nssm\win64\nssm.exe stdout PipecatServer "C:\Project\pipecat-main\logs\stdout.log"
C:\nssm\win64\nssm.exe stderr PipecatServer "C:\Project\pipecat-main\logs\stderr.log"
```

## Bước 8: Cấu hình ngrok

### Khởi động ngrok tunnel

```powershell
C:\ngrok\ngrok.exe http 3000
```

Ngrok sẽ hiển thị URL công khai, ví dụ:

```
https://wedaaa-dovie-uninstructedly.ngrok-aaa.dev -> http://localhost:3000
```

### Chạy ngrok như Windows Service

```powershell
# Tạo file config C:\ngrok\config.yml
echo "authtoken: YOUR_AUTHTOKEN" > C:\ngrok\config.yml
echo "tunnels:" >> C:\ngrok\config.yml
echo "  pipecat:" >> C:\ngrok\config.yml
echo "    addr: 3000" >> C:\ngrok\config.yml
echo "    proto: http" >> C:\ngrok\config.yml

# Tạo service
C:\nssm\win64\nssm.exe install NgrokPipecat "C:\ngrok\ngrok.exe" "start --all --config=C:\ngrok\config.yml"
C:\nssm\win64\nssm.exe set NgrokPipecat AppDirectory "C:\ngrok"
C:\nssm\win64\nssm.exe set NgrokPipecat DisplayName "ngrok Tunnel"
C:\nssm\win64\nssm.exe set NgrokPipecat Start SERVICE_AUTO_START

# Khởi động
C:\nssm\win64\nssm.exe start NgrokPipecat
```

## Bước 9: Cấu hình Flutter App

Trong Flutter app, sử dụng ngrok URL làm Server URL:

```
https://wedaaa-dovie-uninstructedly.ngrok-aaa.dev
```

**KHÔNG cần thêm `/ws`** vì Flutter app tự động thêm vào.

## Bước 10: Kiểm tra kết nối

### Kiểm tra server đang chạy

```powershell
curl http://localhost:3000
```

Expected response:

```json
{"status":"ok","message":"Pipecat WebSocket Server"}
```

### Kiểm tra WebSocket

```powershell
# Cài wscat để test
pip install wscat

# Test kết nối
wscat -c ws://localhost:3000/ws
```

Gửi test message:

```json
{"type":"config","data":{"stt":{"provider":"soniox","api_key":"test"},"llm":{"provider":"openai","api_key":"test","model":"gpt-4o"},"tts":{"provider":"soniox","api_key":"test"}}}
```

### Kiểm tra ngrok tunnel

```powershell
curl https://wedaaa-dovie-uninstructedly.ngrok-aaa.dev
```

Expected response:

```json
{"status":"ok","message":"Pipecat WebSocket Server"}
```

### Kiểm tra từ Flutter app

1. Mở Flutter app
2. Vào AI Translate
3. Nhập Server URL: `https://wedaaa-dovie-uninstructedly.ngrok-aaa.dev`
4. Nhập API keys cho STT, LLM, TTS
5. Nhấn "KẾT NỐI"

## Message Format

### Config message (Flutter → Server)

```json
{
  "type": "config",
  "data": {
    "stt": {
      "provider": "soniox",
      "api_key": "your_soniox_key"
    },
    "llm": {
      "provider": "openai",
      "api_key": "your_openai_key",
      "model": "gpt-4o"
    },
    "tts": {
      "provider": "soniox",
      "api_key": "your_soniox_key"
    },
    "speaker_diarization": true,
    "instant_response": false
  }
}
```

### Transcript message (Server → Flutter)

```json
{
  "type": "transcript",
  "data": {
    "text": "Hello, how are you?",
    "speaker": "user",
    "is_final": true,
    "timestamp": "2024-01-01T12:00:00Z"
  }
}
```

### Bot output message (Server → Flutter)

```json
{
  "type": "bot_output",
  "data": {
    "text": "Xin chào, bạn khỏe không?",
    "spoken": true
  }
}
```

### Error message (Server → Flutter)

```json
{
  "type": "error",
  "data": {
    "message": "Invalid API key for STT provider"
  }
}
```

## Supported Providers

### STT (Speech-to-Text)

| Provider | Package | API Key |
|----------|---------|---------|
| soniox | `pipecat-ai[soniox]` | Soniox API Key |
| deepgram | `pipecat-ai[deepgram]` | Deepgram API Key |
| google | `pipecat-ai[google]` | Google Cloud API Key |
| assemblyai | `pipecat-ai[assemblyai]` | AssemblyAI API Key |
| openai | `pipecat-ai[openai]` | OpenAI API Key |
| whisper | `pipecat-ai[whisper]` | OpenAI API Key |

### LLM (Language Model)

| Provider | Package | API Key |
|----------|---------|---------|
| openai | `pipecat-ai[openai]` | OpenAI API Key |
| anthropic | `pipecat-ai[anthropic]` | Anthropic API Key |
| google | `pipecat-ai[google]` | Google Cloud API Key |
| groq | `pipecat-ai[groq]` | Groq API Key |
| mistral | `pipecat-ai[mistral]` | Mistral API Key |

### TTS (Text-to-Speech)

| Provider | Package | API Key |
|----------|---------|---------|
| soniox | `pipecat-ai[soniox]` | Soniox API Key |
| cartesia | `pipecat-ai[cartesia]` | Cartesia API Key |
| elevenlabs | `pipecat-ai[elevenlabs]` | ElevenLabs API Key |
| openai | `pipecat-ai[openai]` | OpenAI API Key |
| deepgram | `pipecat-ai[deepgram]` | Deepgram API Key |
| google | `pipecat-ai[google]` | Google Cloud API Key |

## Troubleshooting

### Lỗi: Python not found

```powershell
# Kiểm tra Python đã cài chưa
python --version

# Nếu không thấy, thêm Python vào PATH
# Control Panel > System > Advanced system settings > Environment Variables
# Thêm C:\Users\YourUser\AppData\Local\Programs\Python\Python311\ vào PATH
```

### Lỗi: pip not found

```powershell
python -m pip --version
# Nếu không thấy
python -m ensurepip --upgrade
```

### Lỗi: Module not found

```powershell
# Cài lại dependencies
pip install pipecat-ai[all] websockets uvicorn fastapi
```

### Lỗi: Port 3000 already in use

```powershell
# Tìm process đang dùng port 3000
netstat -ano | findstr :3000

# Kill process
taskkill /PID <PID> /F
```

### Lỗi: ngrok tunnel not found

```powershell
# Kiểm tra ngrok có chạy không
C:\ngrok\ngrok.exe version

# Kiểm tra authtoken
C:\ngrok\ngrok.exe config check
```

### Lỗi: WebSocket connection failed

```powershell
# Kiểm tra firewall
# Windows Security > Firewall > Allow an app through firewall
# Cho phép Python và ngrok qua firewall
```

### Lỗi: CORS

Đã cấu hình CORS trong server code. Nếu vẫn lỗi, kiểm tra:

```python
# Trong ws_server.py
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Cho phép tất cả origins
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
```

## Logs

### Xem logs của Pipecat Server

```powershell
# Nếu chạy trực tiếp
# Logs hiển thị trên terminal

# Nếu chạy như service
type C:\pipecat\logs\stdout.log
type C:\pipecat\logs\stderr.log
```

### Xem logs của ngrok

```powershell
# Mở ngrok web interface
start http://localhost:4040
```

## Tài liệu tham khảo

- [Pipecat Documentation](https://docs.pipecat.ai)
- [Pipecat GitHub](https://github.com/pipecat-ai/pipecat)
- [FastAPI WebSocket](https://fastapi.tiangolo.com/advanced/websockets/)
- [ngrok Documentation](https://ngrok.com/docs)
- [Soniox Documentation](https://soniox.com/docs)
- [NSSM Documentation](https://nssm.cc/usage)


Luu y cai python v3.12
Luu y GW phai cai https://aka.ms/vs/17/release/vc_redist.x64.exe va restart windows
Luu y cai pip install "soxr~=1.0.0" --no-cache-dir

Thành phần	Trạng thái cần thiết	Link kiểm tra
PipecatServer	SERVICE_RUNNING	Port 3000
NgrokPipecat	SERVICE_RUNNING	http://127.0.0.1:4041
Internet / Webhook	Thông suốt	Link .ngrok-free.app