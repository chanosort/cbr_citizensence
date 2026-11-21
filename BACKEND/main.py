import os, base64, hashlib, hmac, json, secrets, time, random, mimetypes
from datetime import datetime, timedelta, timezone
from typing import Optional

from dotenv import load_dotenv
from fastapi import FastAPI, Depends, HTTPException, Header, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, FileResponse
from pydantic import BaseModel, EmailStr, Field
from sqlalchemy import create_engine, String, Integer, DateTime, Text, Boolean, Float, select, func
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker, Session

UPLOAD_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'uploads')
os.makedirs(UPLOAD_DIR, exist_ok=True)

_env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.env')
load_dotenv(_env_path)
load_dotenv()
DATABASE_URL = os.getenv('DATABASE_URL', '').strip()
JWT_SECRET = os.getenv('JWT_SECRET', '').strip()
SMTP_HOST = os.getenv('SMTP_HOST', 'smtp.gmail.com').strip()
SMTP_PORT = int(os.getenv('SMTP_PORT', '587'))
SMTP_USER = os.getenv('SMTP_USER', '').strip()
SMTP_PASS = os.getenv('SMTP_PASS', '').replace(' ', '').strip()
APP_EMAIL_FROM = os.getenv('APP_EMAIL_FROM', SMTP_USER).strip()
if not JWT_SECRET:
    raise RuntimeError('JWT_SECRET is missing. Set a long random secret in backend/.env.')

db_engine = None
if DATABASE_URL:
    try:
        candidate_engine = create_engine(DATABASE_URL, pool_pre_ping=True)
        with candidate_engine.connect() as conn:
            pass
        db_engine = candidate_engine
        print('Connected to PostgreSQL successfully.')
    except Exception as e:
        print(f'\n[DATABASE WARNING] Could not connect to PostgreSQL: {e}')
        print('Falling back to SQLite (citizensense.db) so user registration and OTP stay fully operational.\n')

if db_engine is None:
    sqlite_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'citizensense.db')
    db_engine = create_engine(f'sqlite:///{sqlite_path}', connect_args={'check_same_thread': False})
    print(f'Using SQLite database at {sqlite_path}')

engine = db_engine
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)

class Base(DeclarativeBase): pass

# ─── Models ──────────────────────────────────────────────────────────────────

class User(Base):
    __tablename__ = 'citizensense_users'
    id: Mapped[int] = mapped_column(Integer, primary_key=True, index=True)
    name: Mapped[str] = mapped_column(String(160))
    username: Mapped[Optional[str]] = mapped_column(String(50), unique=True, index=True, nullable=True)
    email: Mapped[str] = mapped_column(String(254), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(String(256))
    # Roles: 'citizen' (default on self-registration), 'staff', 'admin'
    # Staff and admin accounts are created ONLY by an existing admin.
    role: Mapped[str] = mapped_column(String(20), default='citizen')
    office_id: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    # Email must be verified before the account can log in
    email_verified: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

class ComplaintRow(Base):
    __tablename__ = 'citizensense_complaints'
    id: Mapped[int] = mapped_column(Integer, primary_key=True, index=True)
    citizen_id: Mapped[int] = mapped_column(Integer, index=True)
    title: Mapped[str] = mapped_column(String(200))
    description: Mapped[str] = mapped_column(Text)
    category_id: Mapped[int] = mapped_column(Integer)
    office_id: Mapped[int] = mapped_column(Integer)
    location_id: Mapped[int] = mapped_column(Integer)
    status: Mapped[str] = mapped_column(String(30), default='submitted')
    priority: Mapped[str] = mapped_column(String(20), default='medium')
    sentiment: Mapped[str] = mapped_column(String(20), default='neutral')
    confidence: Mapped[float] = mapped_column(Float, default=0.0)
    attachment_name: Mapped[Optional[str]] = mapped_column(String(255), nullable=True)
    response_message: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    co_office_ids: Mapped[Optional[str]] = mapped_column(String(100), default='', nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), index=True)

# Stores OTP codes for email verification and password reset.
# Each row is single-use and expires after OTP_TTL_MINUTES.
class OtpToken(Base):
    __tablename__ = 'citizensense_otp_tokens'
    id: Mapped[int] = mapped_column(Integer, primary_key=True, index=True)
    email: Mapped[str] = mapped_column(String(254), index=True)
    # purpose: 'verify_email' | 'reset_password'
    purpose: Mapped[str] = mapped_column(String(30))
    code_hash: Mapped[str] = mapped_column(String(128))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    used: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

Base.metadata.create_all(bind=engine)

app = FastAPI(title='CBR CitizenSense API', version='0.2.0')

app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=r'https?://(localhost|127\.0\.0\.1)(:\d+)?',
    allow_credentials=True,
    allow_methods=['*'],
    allow_headers=['*'],
)

@app.exception_handler(HTTPException)
async def api_error_handler(request: Request, exc: HTTPException):
    detail = exc.detail if isinstance(exc.detail, dict) else {'code': 'REQUEST_ERROR', 'message': str(exc.detail), 'details': {}}
    return JSONResponse(status_code=exc.status_code, content={'error': {'code': detail.get('code', 'REQUEST_ERROR'), 'message': detail.get('message', 'Request failed.'), 'details': detail.get('details', {})}})

# ─── DB helpers ──────────────────────────────────────────────────────────────

def get_db():
    db = SessionLocal()
    try: yield db
    finally: db.close()

def ok(data): return {'data': data}
def fail(status, code, message, details=None):
    raise HTTPException(status_code=status, detail={'code': code, 'message': message, 'details': details or {}})

# ─── Password ─────────────────────────────────────────────────────────────────

OTP_TTL_MINUTES = 10

def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac('sha256', password.encode(), salt, 310000)
    return base64.b64encode(salt + digest).decode()

def verify_password(password: str, stored: str) -> bool:
    try:
        raw = base64.b64decode(stored.encode()); salt, digest = raw[:16], raw[16:]
        return hmac.compare_digest(hashlib.pbkdf2_hmac('sha256', password.encode(), salt, 310000), digest)
    except Exception: return False

def seed_defaults():
    try:
        with SessionLocal() as db:
            default_users = [
                # ── 2 Administrators (Control All) ──────────────────────
                {'name': 'Admin One (System Lead)', 'username': 'admin1', 'email': 'admin1@admin.com', 'role': 'admin', 'office_id': None},
                {'name': 'Admin Two (City Administrator)', 'username': 'admin2', 'email': 'admin2@admin.com', 'role': 'admin', 'office_id': None},
                {'name': 'Admin CitizenSense', 'username': 'admin', 'email': 'admin@admin.com', 'role': 'admin', 'office_id': None},

                # ── Office 1: City Engineering Office (2 Staff) ─────────
                {'name': 'Engr. Carlos Mendoza', 'username': 'eng1', 'email': 'eng1@staff.com', 'role': 'staff', 'office_id': 1},
                {'name': 'Engr. Sarah Dizon', 'username': 'eng2', 'email': 'eng2@staff.com', 'role': 'staff', 'office_id': 1},

                # ── Office 2: City Health Office (2 Staff) ──────────────
                {'name': 'Dr. Pedro Reyes', 'username': 'health1', 'email': 'health1@staff.com', 'role': 'staff', 'office_id': 2},
                {'name': 'Nurse Joy Bautista', 'username': 'health2', 'email': 'health2@staff.com', 'role': 'staff', 'office_id': 2},

                # ── Office 3: City Environment & Natural Resources (2 Staff)
                {'name': 'CENRO Officer Mark Tan', 'username': 'cenro1', 'email': 'cenro1@staff.com', 'role': 'staff', 'office_id': 3},
                {'name': 'CENRO Inspector Leah Cruz', 'username': 'cenro2', 'email': 'cenro2@staff.com', 'role': 'staff', 'office_id': 3},

                # ── Office 4: City Social Welfare & Development (2 Staff)
                {'name': 'CSWDO Worker Grace Aquino', 'username': 'cswdo1', 'email': 'cswdo1@staff.com', 'role': 'staff', 'office_id': 4},
                {'name': 'CSWDO Worker Noel Flores', 'username': 'cswdo2', 'email': 'cswdo2@staff.com', 'role': 'staff', 'office_id': 4},

                # ── Office 5: City Disaster Risk Reduction (2 Staff) ────
                {'name': 'CDRRMO Officer Roberto Lim', 'username': 'drrmo1', 'email': 'drrmo1@staff.com', 'role': 'staff', 'office_id': 5},
                {'name': 'CDRRMO Dispatcher Karen V.', 'username': 'drrmo2', 'email': 'drrmo2@staff.com', 'role': 'staff', 'office_id': 5},

                # ── Office 6: City Public Safety Office (2 Staff) ────────
                {'name': 'PSO Officer Dennis Castro', 'username': 'safety1', 'email': 'safety1@staff.com', 'role': 'staff', 'office_id': 6},
                {'name': 'PSO Marshall Liza Ramos', 'username': 'safety2', 'email': 'safety2@staff.com', 'role': 'staff', 'office_id': 6},

                # ── Office 7: City Mayor\'s Office (2 Staff) ─────────────
                {'name': 'Mayors Aide Antonio Luna', 'username': 'mayor1', 'email': 'mayor1@staff.com', 'role': 'staff', 'office_id': 7},
                {'name': 'Mayors Officer Beatriz Gomez', 'username': 'mayor2', 'email': 'mayor2@staff.com', 'role': 'staff', 'office_id': 7},

                # ── Citizens ─────────────────────────────────────────────
                {'name': 'Juan Dela Cruz', 'username': 'juan', 'email': 'citizen@gmail.com', 'role': 'citizen', 'office_id': None},
            ]

            added = 0
            for u in default_users:
                exists = db.scalar(select(User).where(
                    (func.lower(User.email) == u['email'].lower()) |
                    (func.lower(User.username) == u['username'].lower())
                ))
                if not exists:
                    db.add(User(
                        name=u['name'],
                        username=u['username'],
                        email=u['email'],
                        password_hash=hash_password('password123'),
                        role=u['role'],
                        office_id=u['office_id'],
                        active=True,
                        email_verified=True,
                    ))
                    added += 1
            if added > 0:
                db.commit()
                print(f'Default accounts seeded successfully: {added} users added.')
    except Exception as e:
        print(f'Seed check skipped: {e}')

seed_defaults()

def _hash_otp(code: str) -> str:
    return hashlib.sha256(code.encode()).hexdigest()

# ─── JWT ──────────────────────────────────────────────────────────────────────

def b64(data: bytes) -> str: return base64.urlsafe_b64encode(data).rstrip(b'=').decode()

def make_token(user: User) -> str:
    now = int(time.time())
    head = b64(json.dumps({'alg': 'HS256', 'typ': 'JWT'}, separators=(',', ':')).encode())
    payload = b64(json.dumps({'sub': user.id, 'role': user.role, 'iat': now, 'exp': now + 60 * 60 * 8}, separators=(',', ':')).encode())
    message = f'{head}.{payload}'
    sig = b64(hmac.new(JWT_SECRET.encode(), message.encode(), hashlib.sha256).digest())
    return f'{message}.{sig}'

def decode_token(token: str):
    try:
        head, payload, sig = token.split('.')
        message = f'{head}.{payload}'
        expected = b64(hmac.new(JWT_SECRET.encode(), message.encode(), hashlib.sha256).digest())
        if not hmac.compare_digest(sig, expected): raise ValueError()
        data = json.loads(base64.urlsafe_b64decode(payload + '=' * ((4 - len(payload) % 4) % 4)))
        if int(data['exp']) < int(time.time()): raise ValueError()
        return data
    except Exception:
        raise HTTPException(401, detail={'code': 'INVALID_TOKEN', 'message': 'Session expired or invalid.', 'details': {}})

# ─── Auth dependencies ────────────────────────────────────────────────────────

def current_user(authorization: Optional[str] = Header(default=None), db: Session = Depends(get_db)) -> User:
    if not authorization or not authorization.startswith('Bearer '):
        raise HTTPException(401, detail={'code': 'UNAUTHORIZED', 'message': 'Please log in.', 'details': {}})
    payload = decode_token(authorization[7:])
    user = db.get(User, int(payload['sub']))
    if not user or not user.active:
        raise HTTPException(401, detail={'code': 'UNAUTHORIZED', 'message': 'Account unavailable.', 'details': {}})
    return user

def require_role(user: User, *roles):
    if user.role not in roles:
        raise HTTPException(403, detail={'code': 'FORBIDDEN', 'message': 'You are not authorized for this action.', 'details': {}})

# ─── Email (SMTP) ─────────────────────────────────────────────────────────────

def _send_email(to: str, subject: str, body: str):
    """Send a plain-text email via SMTP.
    If SMTP_USER / SMTP_PASS are not configured or are placeholder values,
    the OTP is printed prominently to the server console (dev mode fallback).
    """
    is_placeholder = (
        not SMTP_USER 
        or not SMTP_PASS 
        or 'your_gmail' in SMTP_USER.lower() 
        or 'your_gmail' in SMTP_PASS.lower()
    )
    if is_placeholder:
        print('\n' + '=' * 60)
        print(f' [DEV EMAIL OTP] Delivered to: {to}')
        print(f' Subject: {subject}')
        print('-' * 60)
        print(body.strip())
        print('=' * 60 + '\n')
        return

    try:
        import smtplib
        from email.mime.text import MIMEText
        msg = MIMEText(body)
        msg['Subject'] = subject
        msg['From'] = APP_EMAIL_FROM or SMTP_USER
        msg['To'] = to
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=10) as s:
            s.starttls()
            s.login(SMTP_USER, SMTP_PASS)
            s.sendmail(msg['From'], [to], msg.as_string())
    except Exception as e:
        print(f'\n[SMTP ERROR] Could not send email via SMTP ({e}).')
        print(f'Fallback OTP printed to console for: {to}\n{body}\n')

def _issue_otp(db: Session, email: str, purpose: str) -> str:
    """Generate a 6-digit OTP, store its hash, invalidate old ones, return the plain code."""
    old = db.scalars(select(OtpToken).where(
        OtpToken.email == email,
        OtpToken.purpose == purpose,
        OtpToken.used == False,
    )).all()
    for o in old:
        o.used = True

    code = f'{random.SystemRandom().randint(0, 999999):06d}'
    expires_at = datetime.now(timezone.utc) + timedelta(minutes=OTP_TTL_MINUTES)
    db.add(OtpToken(email=email, purpose=purpose, code_hash=_hash_otp(code), expires_at=expires_at))
    db.commit()
    return code

def _verify_otp(db: Session, email: str, purpose: str, code: str) -> bool:
    """Return True if the OTP is valid; mark it used."""
    row = db.scalar(select(OtpToken).where(
        OtpToken.email == email,
        OtpToken.purpose == purpose,
        OtpToken.used == False,
        OtpToken.expires_at > datetime.now(timezone.utc),
    ).order_by(OtpToken.created_at.desc()))
    if not row or not hmac.compare_digest(row.code_hash, _hash_otp(code)):
        return False
    row.used = True
    db.commit()
    return True

# ─── Serialisers ─────────────────────────────────────────────────────────────

def user_json(u): return {'id': u.id, 'name': u.name, 'username': u.username or '', 'email': u.email, 'role': u.role, 'office_id': u.office_id, 'active': u.active}
def iso(dt): return (dt or datetime.now(timezone.utc)).isoformat()
def complaint_json(c: ComplaintRow, db: Session):
    u = db.get(User, c.citizen_id)
    co_ids = [int(x) for x in (c.co_office_ids or '').split(',') if x.strip().isdigit()]
    return {
        'id': c.id,
        'title': c.title,
        'description': c.description,
        'category_id': c.category_id,
        'office_id': c.office_id,
        'co_office_ids': co_ids,
        'location_id': c.location_id,
        'status': c.status,
        'priority': c.priority,
        'sentiment': c.sentiment,
        'created_at': iso(c.created_at),
        'citizen_name': u.name if u else '',
        'citizen_email': u.email if u else '',
        'attachment_name': c.attachment_name,
        'attachment_url': f'/api/complaints/{c.id}/attachment' if c.attachment_name else None,
    }

# ─── Request schemas ──────────────────────────────────────────────────────────

class RegisterIn(BaseModel):
    name: str = Field(min_length=2, max_length=160)
    username: str = Field(min_length=3, max_length=50, pattern=r'^[a-zA-Z0-9_]+$')
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)
    # office_id intentionally omitted — public registration is citizens-only.

class VerifyEmailIn(BaseModel):
    email: EmailStr
    code: str = Field(min_length=6, max_length=6)

class ResendVerifyIn(BaseModel):
    email: EmailStr

class LoginIn(BaseModel):
    account: Optional[str] = None
    email: Optional[str] = None
    password: str

class ForgotPasswordIn(BaseModel):
    account: Optional[str] = None
    email: Optional[str] = None

class ResetPasswordIn(BaseModel):
    account: Optional[str] = None
    email: Optional[str] = None
    code: str = Field(min_length=6, max_length=6)
    new_password: str = Field(min_length=8, max_length=128)

class ComplaintIn(BaseModel):
    title: str = Field(min_length=3, max_length=200)
    description: str = Field(min_length=10, max_length=10000)
    category_id: int = Field(ge=1)
    office_id: int = Field(ge=1)
    location_id: int = Field(ge=1)

class ClassifyIn(BaseModel): category_id: Optional[int] = None; description: str
class StatusIn(BaseModel): status: str; response_message: Optional[str] = None
class ChangePasswordIn(BaseModel): current_password: str; new_password: str = Field(min_length=8, max_length=128)

# Admin-only schema for creating staff / admin accounts
class AdminCreateUserIn(BaseModel):
    name: str = Field(min_length=2, max_length=160)
    username: Optional[str] = Field(default=None, max_length=50)
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)
    role: str  # 'staff' or 'admin'
    office_id: Optional[int] = None  # required when role == 'staff'

# ─── Health ───────────────────────────────────────────────────────────────────

@app.get('/')
def home(): return {'message': 'CBR CitizenSense API is running', 'docs': '/docs'}

@app.get('/health')
@app.get('/api/health')
@app.get('/api/health/db')
def health(db: Session = Depends(get_db)):
    db.execute(select(1)); return {'database': 'connected', 'status': 'ok'}

# ─── Auth: Register (citizens only) ──────────────────────────────────────────

@app.post('/api/auth/register')
def register(data: RegisterIn, db: Session = Depends(get_db)):
    """
    Self-registration is restricted to the 'citizen' role.
    User specifies their full name, unique username, and legitimate email.
    A 6-digit OTP is sent to the supplied email; the account cannot log in
    until it is verified via POST /api/auth/verify-email.
    """
    username = data.username.lower().strip()
    email = str(data.email).lower().strip()

    if db.scalar(select(User).where(func.lower(User.username) == username)):
        raise HTTPException(409, detail={'code': 'USERNAME_EXISTS', 'message': 'An account with this username already exists.', 'details': {}})

    if db.scalar(select(User).where(func.lower(User.email) == email)):
        raise HTTPException(409, detail={'code': 'EMAIL_EXISTS', 'message': 'An account with this email already exists.', 'details': {}})

    # Enforce least privilege: self-registration is always 'citizen'.
    user = User(
        name=data.name.strip(),
        username=username,
        email=email,
        password_hash=hash_password(data.password),
        role='citizen',
        office_id=None,
        active=True,
        email_verified=False,
    )
    db.add(user); db.commit(); db.refresh(user)

    # Also synchronize to users_tbl so it appears in pgAdmin
    try:
        from sqlalchemy import text
        parts = data.name.strip().split(' ', 1)
        first_name = parts[0]
        last_name = parts[1] if len(parts) > 1 else ''
        db.execute(text("""
            INSERT INTO users_tbl (first_name, last_name, email, passwords, created_at)
            VALUES (:fn, :ln, :em, :pwd, NOW())
            ON CONFLICT (email) DO NOTHING
        """), {'fn': first_name, 'ln': last_name, 'em': email, 'pwd': user.password_hash})
        db.commit()
    except Exception as e:
        db.rollback()
        print(f"Notice: users_tbl sync: {e}")

    code = _issue_otp(db, email, 'verify_email')
    _send_email(
        to=email,
        subject='CBR CitizenSense – Verify your email',
        body=(
            f'Hi {data.name.strip()},\n\n'
            f'Thank you for registering on Cabadbaran CitizenSense (@{username}).\n\n'
            f'Your verification code is: {code}\n\n'
            f'This code expires in {OTP_TTL_MINUTES} minutes.\n\n'
            'If you did not create this account, please ignore this email.\n\n'
            '— CBR CitizenSense Team'
        ),
    )
    return ok({'id': user.id, 'username': user.username, 'email': user.email, 'message': 'Registration successful. Check your email for the verification code.'})

# ─── Auth: Verify email ───────────────────────────────────────────────────────

@app.post('/api/auth/verify-email')
def verify_email(data: VerifyEmailIn, db: Session = Depends(get_db)):
    """Mark the account as verified after the citizen enters the OTP."""
    email = str(data.email).lower().strip()
    user = db.scalar(select(User).where(User.email == email))
    if not user:
        raise HTTPException(404, detail={'code': 'NOT_FOUND', 'message': 'No account found with this email.', 'details': {}})
    if user.email_verified:
        return ok({'message': 'Email already verified. You can log in.'})
    if not _verify_otp(db, email, 'verify_email', data.code.strip()):
        raise HTTPException(400, detail={'code': 'INVALID_CODE', 'message': 'The code is incorrect or has expired.', 'details': {}})
    user.email_verified = True
    db.commit()
    return ok({'message': 'Email verified. You can now log in.'})

# ─── Auth: Resend verification code ──────────────────────────────────────────

@app.post('/api/auth/resend-verification')
def resend_verification(data: ResendVerifyIn, db: Session = Depends(get_db)):
    email = str(data.email).lower().strip()
    user = db.scalar(select(User).where(User.email == email))
    if user and not user.email_verified:
        code = _issue_otp(db, email, 'verify_email')
        _send_email(
            to=email,
            subject='CBR CitizenSense – Verify your email (resent)',
            body=(
                f'Hi {user.name},\n\n'
                f'Your new verification code is: {code}\n\n'
                f'This code expires in {OTP_TTL_MINUTES} minutes.\n'
            ),
        )
    # Always return 200 to prevent email enumeration
    return ok({'message': 'If that email is registered and unverified, a new code has been sent.'})

# ─── Auth: Login ──────────────────────────────────────────────────────────────

@app.post('/api/auth/login')
def login(data: LoginIn, db: Session = Depends(get_db)):
    ident = str(data.account or data.email or '').lower().strip()
    user = db.scalar(select(User).where(
        (func.lower(User.email) == ident) | (func.lower(User.username) == ident)
    ))
    if not user or not verify_password(data.password, user.password_hash) or not user.active:
        raise HTTPException(401, detail={'code': 'INVALID_CREDENTIALS', 'message': 'Username/email or password is incorrect.', 'details': {}})
    if not user.email_verified:
        raise HTTPException(403, detail={'code': 'EMAIL_NOT_VERIFIED', 'message': 'Please verify your email before logging in. Check your inbox for the verification code.', 'details': {}})
    return ok({'user': user_json(user), 'token': make_token(user)})

# ─── Auth: Forgot password ───────────────────────────────────────────────────

@app.post('/api/auth/forgot-password')
def forgot_password(data: ForgotPasswordIn, db: Session = Depends(get_db)):
    """Send an account recovery OTP to the email on file. Accepts username or email."""
    ident = str(data.account or data.email or '').lower().strip()
    user = db.scalar(select(User).where(
        (func.lower(User.email) == ident) | (func.lower(User.username) == ident)
    ))
    masked_email = ''
    if user and user.active:
        code = _issue_otp(db, user.email, 'reset_password')
        _send_email(
            to=user.email,
            subject='CBR CitizenSense – Account Recovery Code',
            body=(
                f'Hi {user.name},\n\n'
                f'You requested an account recovery code for your CitizenSense account (@{user.username or user.name}).\n\n'
                f'Your recovery code is: {code}\n\n'
                f'This code expires in {OTP_TTL_MINUTES} minutes.\n\n'
                'If you did not request this, please ignore this email and your password will remain unchanged.\n\n'
                '— CBR CitizenSense Team'
            ),
        )
        parts = user.email.split('@')
        if len(parts) == 2:
            n, d = parts[0], parts[1]
            masked_name = (n[0] + '***' + n[-1]) if len(n) > 2 else (n[0] + '***')
            masked_email = f'{masked_name}@{d}'
    return ok({'message': 'If that account is registered, a reset code has been sent.', 'email': masked_email})

# ─── Auth: Reset password ─────────────────────────────────────────────────────

@app.post('/api/auth/reset-password')
def reset_password(data: ResetPasswordIn, db: Session = Depends(get_db)):
    ident = str(data.account or data.email or '').lower().strip()
    user = db.scalar(select(User).where(
        (func.lower(User.email) == ident) | (func.lower(User.username) == ident)
    ))
    if not user or not user.active:
        raise HTTPException(400, detail={'code': 'INVALID_CODE', 'message': 'The code is incorrect or has expired.', 'details': {}})
    if not _verify_otp(db, user.email, 'reset_password', data.code.strip()):
        raise HTTPException(400, detail={'code': 'INVALID_CODE', 'message': 'The code is incorrect or has expired.', 'details': {}})
    user.password_hash = hash_password(data.new_password)
    db.commit()
    return ok({'message': 'Password reset successfully. You can now log in.'})

# ─── Auth: Change password (authenticated) ────────────────────────────────────

@app.post('/api/auth/change-password')
def change_password(data: ChangePasswordIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    if not verify_password(data.current_password, user.password_hash):
        raise HTTPException(400, detail={'code': 'PASSWORD_MISMATCH', 'message': 'Current password is incorrect.', 'details': {}})
    user.password_hash = hash_password(data.new_password); db.commit()
    return ok({'message': 'Password updated.'})

# ─── NLP Text Classifier ──────────────────────────────────────────────────────

# Category keyword dictionary (English + Filipino/Bisaya) for text-based classification.
# Each category maps to: (category_id, default_office_id, [keywords])
_NLP_CATEGORIES = {
    'Roads & Infrastructure': (1, 1, [
        # Cebuano
        'dalan', 'kalsada', 'guba nga dalan', 'lubak', 'libaong', 'lungag', 'liki',
        'tulay', 'taytayan', 'nahugno', 'natumpag', 'semento', 'aspalto', 'ali sa dalan',
        'giuba nga building', 'giuba ga building', 'giuba', 'building', 'edipisyo', 'giniba',
        'demolisyon', 'demolition', 'konstruksyon', 'bungkag', 'naguba nga edipisyo', 'pagguba',
        # Tagalog
        'kalsada', 'daan', 'lubak', 'butas sa daan', 'bitak', 'sira ang kalsada', 'tulay',
        'gumuho', 'semento', 'aspalto', 'poste', 'manhole', 'nakaharang', 'ginibang building',
        # English
        'road', 'pothole', 'damaged road', 'broken street', 'cracked pavement', 'bridge',
        'asphalt', 'concrete', 'collapsed', 'repair road', 'sidewalk', 'manhole cover',
        'excavation', 'infrastructure', 'street light pole', 'demolished building', 'building demolition'
    ]),
    'Streetlights & Electricity': (2, 1, [
        # Cebuano
        'suga sa dalan', 'walay suga', 'ngitngit', 'kuryente', 'brownout', 'blackout',
        'poste sa kuryente', 'natumba nga poste', 'alambre', 'putol nga wire', 'nagbitay nga kable',
        # Tagalog
        'ilaw sa kalsada', 'walang ilaw', 'madilim', 'kuryente', 'brownout', 'blackout',
        'poste ng kuryente', 'natumbang poste', 'nakabiting wire', 'putol na kawad',
        # English
        'streetlight', 'dark street', 'no street light', 'power outage', 'blackout',
        'brownout', 'electric post', 'fallen pole', 'exposed wire', 'dangling wire', 'transformer'
    ]),
    'Drainage & Flooding': (3, 5, [
        # Cebuano
        'baha', 'lunop', 'niawas ang kanal', 'barado nga kanal', 'clogged drainage',
        'tubig baha', 'sapa', 'suba', 'landslide', 'dahili sa yuta', 'evacuation', 'miawas ang sapa',
        # Tagalog
        'baha', 'umaapaw ang kanal', 'baradong drainage', 'baradong kanal', 'bumaha',
        'tubig baha', 'ilog', 'sapa', 'landslide', 'pagguho ng lupa', 'paglikas',
        # English
        'flood', 'flooding', 'flash flood', 'clogged drainage', 'blocked canal',
        'overflowing drain', 'storm drain', 'stagnant water', 'waterlogging', 'creek overflow', 'landslide'
    ]),
    'Garbage & Sanitation': (4, 3, [
        # Cebuano
        'basura', 'hugaw', 'baho', 'wala gihakot nga basura', 'tambak nga basura',
        'dumpsite', 'paglabay ug basura', 'piggery nga baho', 'hugaw sa baboy', 'baho sa manokan',
        'laina sa hangin', 'lainas hangin', 'laina ug hangin', 'abog', 'hugaw nga hangin',
        'abog kaayo', 'polusyon', 'aso', 'baho nga aso', 'hangin nga baho', 'pwerte ka abog',
        # Tagalog
        'basura', 'marumi', 'mabaho', 'hindi kinokolekta ang basura', 'tambak na basura',
        'tapon ng basura', 'amoy piggery', 'amoy babuyan', 'amoy manukan', 'dumpsite', 'kalat',
        'maruming hangin', 'mabahong hangin', 'polusyon sa hangin', 'alikabok', 'maalikabok',
        # English
        'garbage', 'trash', 'waste', 'uncollected garbage', 'garbage pile', 'dumpsite',
        'foul odor', 'stinking', 'piggery smell', 'poultry smell', 'illegal dumping', 'litter',
        'air pollution', 'foul air', 'dust pollution', 'heavy dust', 'smoke', 'toxic air', 'bad air quality'
    ]),
    'Health Concerns': (5, 2, [
        # Cebuano
        'sakit', 'hilanat', 'dengue', 'health center', 'tambalanan', 'tambal', 'doktor',
        'nars', 'bakuna', 'iro nga laag', 'napaakan ug iro', 'kagat sa iro', 'rabies',
        'kalibanga', 'pan-os nga pagkaon', 'hilo sa pagkaon',
        # Tagalog
        'sakit', 'lagnat', 'dengue', 'health center', 'ospital', 'gamot', 'doktor',
        'nars', 'bakuna', 'asong gala', 'nakagat ng aso', 'kagat ng aso', 'rabies',
        'pagtatae', 'food poisoning', 'sirang pagkain',
        # English
        'health', 'hospital', 'clinic', 'health center', 'medicine', 'dengue', 'fever',
        'disease', 'illness', 'rabies', 'dog bite', 'stray dog', 'food poisoning', 'contamination'
    ]),
    'Peace, Order & Public Safety': (6, 6, [
        # Cebuano
        'kawat', 'kawatan', 'tulis', 'holdap', 'away', 'kagubot', 'sinumbagay', 'dunggab',
        'pusil', 'buto sa pusil', 'droga', 'shabu', 'hubog nga nanggubot', 'estambay', 'hulga',
        # Tagalog
        'magnanakaw', 'holdap', 'nakawan', 'away', 'kaguluhan', 'suntukan', 'saksakan',
        'baril', 'putok ng baril', 'droga', 'shabu', 'lasing na nagwawala', 'estambay', 'banta',
        # English
        'theft', 'robbery', 'burglar', 'fight', 'violence', 'stabbing', 'gunshot',
        'shooting', 'illegal drugs', 'public intoxication', 'drunkard disturbance', 'threat'
    ]),
    'Traffic & Transport': (7, 6, [
        # Cebuano
        'trapiko', 'huot ang kalsada', 'aksidente sa motor', 'nabanggaan', 'disgrasya',
        'illegal parking', 'nagbabag sa dalan', 'tricycle nga paspas', 'counterflow',
        # Tagalog
        'trapik', 'traffic', 'aksidente sa motor', 'nabangga', 'disgrasya', 'illegal parking',
        'nakaharang sa daan', 'pasaway na driver', 'counterflow',
        # English
        'traffic', 'traffic congestion', 'vehicle accident', 'motorcycle crash', 'collision',
        'illegal parking', 'road obstruction', 'reckless driving'
    ]),
    'Social Welfare & Assistance': (8, 4, [
        # Cebuano
        'ayuda', 'tabang pinansyal', 'kabus', 'senior citizen', 'tiguwang', 'pwd',
        'bakol', 'solo parent', 'bata nga giabuso', 'giabandonar nga bata', '4ps', 'tabang sa lubong',
        # Tagalog
        'ayuda', 'tulong pinansyal', 'mahirap', 'senior citizen', 'matanda', 'pwd',
        'may kapansanan', 'solo parent', 'batang inabuso', '4ps', 'tulong sa libing',
        # English
        'financial assistance', 'ayuda', 'senior citizen', 'pwd', 'disability',
        'solo parent', 'child abuse', 'burial assistance', 'indigent assistance', 'social welfare'
    ]),
    'Noise & Public Nuisance': (9, 6, [
        # Cebuano
        'saba', 'pwerteng sabaha', 'videoke nga saba', 'karaoke sa gabii', 'saba sa silingan',
        'usig sa iro', 'disco sa karsada', 'kusog kaayong speaker',
        # Tagalog
        'ingay', 'sobrang ingay', 'videoke sa hatinggabi', 'karaoke na maingay', 'ingay ng kapitbahay',
        'tahol ng aso', 'napakalakas na speaker', 'videoke',
        # English
        'noise complaint', 'loud music', 'karaoke late at night', 'videoke disturbance',
        'barking dog', 'loud speaker', 'public nuisance'
    ]),
    'Other Concerns': (10, 7, [
        # Cebuano
        'mayor', 'reklamo sa barangay', 'opisyal', 'kapitan', 'pangutana', 'sugyot',
        # Tagalog
        'tanggapan ng mayor', 'reklamo sa barangay', 'kapitan', 'opisyal', 'suhestiyon',
        # English
        'mayor office', 'barangay official', 'general inquiry', 'city hall feedback', 'other concern'
    ]),
}

# Priority keywords with scoring
_PRIORITY_RULES = [
    ('critical', 10, [
        'life-threatening', 'trapped', 'collapsed', 'severe injury', 'fire spreading',
        'patay', 'dead', 'dying', 'emergency', 'rescue', 'nag-collapse',
    ]),
    ('high', 6, [
        'flood', 'baha', 'exposed wire', 'no electricity', 'accident', 'aksidente',
        'injury', 'dangerous', 'overflow', 'dengue', 'outbreak', 'shooting',
        'robbery', 'kawatan', 'fire', 'sunog', 'drug', 'stabbing',
    ]),
    ('medium', 3, [
        'broken', 'damaged', 'not working', 'garbage', 'noise', 'leak',
        'pothole', 'butas', 'clogged', 'stink', 'baho', 'dark', 'unsafe',
        'reckless', 'uncollected', 'stagnant',
    ]),
]

_OFFICE_NAMES = {
    1: 'City Engineering Office',
    2: 'City Health Office',
    3: 'City Environment & Natural Resources Office (CENRO)',
    4: 'City Social Welfare & Development Office (CSWDO)',
    5: 'City Disaster Risk Reduction & Management Office (CDRRMO)',
    6: 'City Public Safety Office (PSO)',
    7: "City Mayor's Office",
}

def _nlp_classify(description: str, category_id: Optional[int] = None):
    """
    NLP text classifier that determines category, priority, sentiment,
    and suggested primary and co-assigned offices from the complaint description.
    """
    text = description.lower().strip()
    words = text.split()

    # ── Auto-detect category & all involved offices from text ─────────
    category_scores = {}
    office_scores = {}
    best_cat = 'Other Concerns'
    best_score = 0
    matched_keywords = []

    for cat_name, (cat_id, office_id, keywords) in _NLP_CATEGORIES.items():
        score = 0
        hits = []
        for kw in keywords:
            if kw in text:
                # Longer keyword matches score higher (more specific)
                score += len(kw.split())
                hits.append(kw)
        if score > 0:
            category_scores[cat_name] = (cat_id, office_id, score)
            office_scores[office_id] = office_scores.get(office_id, 0) + score
        if score > best_score:
            best_score = score
            best_cat = cat_name
            matched_keywords = hits

    detected_cat_id, detected_office_id, _ = _NLP_CATEGORIES[best_cat]

    # If user explicitly chose a category, use that; otherwise use detected
    final_cat_id = category_id if category_id else detected_cat_id
    final_cat_name = best_cat
    if category_id:
        for cname, (cid, oid, _) in _NLP_CATEGORIES.items():
            if cid == category_id:
                final_cat_name = cname
                detected_office_id = oid
                break

    # ── Multi-Office Dispatch Detection ──────────────────────────────
    sorted_office_ids = sorted(office_scores.keys(), key=lambda oid: office_scores[oid], reverse=True)
    if not sorted_office_ids:
        sorted_office_ids = [detected_office_id]
    
    primary_office_id = detected_office_id
    all_office_ids = [primary_office_id]
    for oid in sorted_office_ids:
        if oid not in all_office_ids:
            all_office_ids.append(oid)
    co_office_ids = [oid for oid in all_office_ids if oid != primary_office_id]
    office_names = [_OFFICE_NAMES.get(oid, f"Office {oid}") for oid in all_office_ids]

    # ── Priority detection ────────────────────────────────────────────
    priority_score = 0
    priority = 'low'
    for level, weight, keywords in _PRIORITY_RULES:
        for kw in keywords:
            if kw in text:
                if weight > priority_score:
                    priority_score = weight
                    priority = level

    # ── Sentiment detection ───────────────────────────────────────────
    negative_words = [
        'bad', 'terrible', 'worst', 'angry', 'disgusted', 'frustrated',
        'disappointed', 'horrible', 'awful', 'hate', 'galit', 'bwiset',
        'walang kwenta', 'incompetent', 'useless', 'negligent',
        'dangerous', 'unsafe', 'unacceptable', 'complaint', 'reklamo',
    ]
    positive_words = ['thank', 'good', 'great', 'appreciate', 'salamat', 'maayo']

    neg_count = sum(1 for w in negative_words if w in text)
    pos_count = sum(1 for w in positive_words if w in text)
    sentiment = 'negative' if neg_count > pos_count else 'positive' if pos_count > neg_count else 'neutral'
    if priority in ('high', 'critical'):
        sentiment = 'negative'

    # ── Confidence calculation ────────────────────────────────────────
    word_count = len(words)
    keyword_hits = len(matched_keywords)
    if word_count < 5:
        confidence = 0.25
    elif keyword_hits == 0:
        confidence = 0.30
    elif keyword_hits == 1:
        confidence = 0.55
    elif keyword_hits == 2:
        confidence = 0.72
    else:
        confidence = min(0.95, 0.72 + keyword_hits * 0.05)

    if category_id and category_id == detected_cat_id:
        confidence = min(0.98, confidence + 0.15)

    category_only = len(text) < 10 and category_id is not None

    return {
        'category': final_cat_name,
        'category_id': final_cat_id,
        'detected_category_id': detected_cat_id,
        'sentiment': sentiment,
        'priority': priority,
        'confidence': round(confidence, 2),
        'office_id': primary_office_id,
        'co_office_ids': co_office_ids,
        'all_office_ids': all_office_ids,
        'office_names': office_names,
        'keywords': matched_keywords[:6],
        'category_only': category_only,
    }


@app.post('/api/complaints/classify')
def classify(data: ClassifyIn, user: User = Depends(current_user)):
    result = _nlp_classify(data.description, data.category_id)
    return ok(result)

# ─── Complaints ───────────────────────────────────────────────────────────────

@app.post('/api/complaints')
async def create_complaint(request: Request, user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, 'citizen')
    content_type = request.headers.get('content-type', '').lower()
    attachment_filename = None

    if 'multipart/form-data' in content_type:
        form = await request.form()
        title = str(form.get('title', '')).strip()
        description = str(form.get('description', '')).strip()
        try:
            category_id = int(form.get('category_id', 1))
            office_id = int(form.get('office_id', 1))
            location_id = int(form.get('location_id', 1))
        except (ValueError, TypeError):
            raise HTTPException(422, detail={'code': 'VALIDATION_ERROR', 'message': 'Invalid category, office, or location ID.'})

        file_field = form.get('attachment')
        if file_field and hasattr(file_field, 'filename') and file_field.filename:
            raw_name = os.path.basename(file_field.filename)
            safe_name = f"{int(time.time())}_{secrets.token_hex(4)}_{raw_name}"
            save_path = os.path.join(UPLOAD_DIR, safe_name)
            content = await file_field.read()
            with open(save_path, 'wb') as f:
                f.write(content)
            attachment_filename = safe_name
    else:
        try:
            body = await request.json()
        except Exception:
            raise HTTPException(400, detail={'code': 'BAD_REQUEST', 'message': 'Invalid JSON or multipart body.'})
        data = ComplaintIn(**body)
        title = data.title.strip()
        description = data.description.strip()
        category_id = data.category_id
        office_id = data.office_id
        location_id = data.location_id

    if len(title) < 3 or len(description) < 10:
        raise HTTPException(422, detail={'code': 'VALIDATION_ERROR', 'message': 'Title must be at least 3 characters and description at least 10 characters.'})

    nlp = _nlp_classify(description, category_id)
    all_oids = nlp.get('all_office_ids', [office_id])
    co_ids_str = ",".join(str(o) for o in all_oids if o != office_id)
    c = ComplaintRow(
        citizen_id=user.id,
        title=title,
        description=description,
        category_id=category_id,
        office_id=office_id,
        co_office_ids=co_ids_str,
        location_id=location_id,
        status='submitted',
        priority=nlp['priority'],
        sentiment=nlp['sentiment'],
        confidence=nlp['confidence'],
        attachment_name=attachment_filename
    )
    db.add(c); db.commit(); db.refresh(c)

    # Synchronize to complaints_tbl so it immediately shows in pgAdmin
    try:
        from sqlalchemy import text
        u_id = db.execute(text("SELECT user_id FROM users_tbl WHERE email = :em"), {'em': user.email}).scalar()
        if not u_id:
            u_id = 1
        risk_map = {'low': 1, 'medium': 2, 'high': 3, 'critical': 4}
        r_id = risk_map.get(nlp.get('priority', 'medium'), 2)
        db.execute(text("""
            INSERT INTO complaints_tbl (
                user_id, office_id, category_id, location_id, risk_level_id, status_id,
                title, description, attachment, date_submitted
            ) VALUES (
                :uid, :oid, :cid, :lid, :rid, 1,
                :title, :desc, :att, NOW()
            )
        """), {
            'uid': u_id,
            'oid': office_id,
            'cid': category_id,
            'lid': location_id,
            'rid': r_id,
            'title': title,
            'desc': description,
            'att': attachment_filename or '',
        })
        db.commit()
    except Exception as e:
        db.rollback()
        print(f"Notice: complaints_tbl sync: {e}")

    return ok(complaint_json(c, db))

@app.get('/api/complaints/{complaint_id}/attachment')
def get_complaint_attachment(
    complaint_id: int,
    token: Optional[str] = None,
    authorization: Optional[str] = Header(default=None),
    db: Session = Depends(get_db)
):
    raw_token = None
    if authorization and authorization.startswith('Bearer '):
        raw_token = authorization[7:].strip()
    elif token:
        raw_token = token.strip()

    if not raw_token:
        raise HTTPException(401, detail={'code': 'UNAUTHORIZED', 'message': 'Authentication required to view attachment.'})

    try:
        payload = decode_token(raw_token)
        user = db.get(User, int(payload['sub']))
        if not user or not user.active:
            raise ValueError()
    except Exception:
        raise HTTPException(401, detail={'code': 'UNAUTHORIZED', 'message': 'Invalid or expired session.'})

    c = db.get(ComplaintRow, complaint_id)
    if not c or not c.attachment_name:
        raise HTTPException(404, detail={'code': 'NOT_FOUND', 'message': 'Attachment not found.'})

    # Permission check: Citizen owner, Admin, or Staff of the assigned/co-office
    co_ids = [int(x) for x in (c.co_office_ids or '').split(',') if x.strip().isdigit()]
    if user.role == 'citizen' and c.citizen_id != user.id:
        raise HTTPException(403, detail={'code': 'FORBIDDEN', 'message': 'Not your complaint.'})
    if user.role == 'staff' and c.office_id != user.office_id and user.office_id not in co_ids:
        raise HTTPException(403, detail={'code': 'FORBIDDEN', 'message': 'Not assigned to your office.'})

    file_path = os.path.join(UPLOAD_DIR, c.attachment_name)
    if not os.path.isfile(file_path):
        raise HTTPException(404, detail={'code': 'NOT_FOUND', 'message': 'File missing from server disk.'})

    mime, _ = mimetypes.guess_type(file_path)
    return FileResponse(file_path, media_type=mime or 'application/octet-stream', filename=c.attachment_name)

@app.get('/api/complaints')
def list_own(user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, 'citizen')
    rows = list(db.scalars(select(ComplaintRow).where(ComplaintRow.citizen_id == user.id).order_by(ComplaintRow.created_at.desc())))
    return ok({'items': [complaint_json(c, db) for c in rows]})

@app.get('/api/staff/complaints')
def list_staff(user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, 'staff')
    user_oid = str(user.office_id)
    rows = list(db.scalars(
        select(ComplaintRow).where(
            (ComplaintRow.office_id == user.office_id) |
            (ComplaintRow.co_office_ids.like(f'%{user_oid}%'))
        ).order_by(ComplaintRow.created_at.desc())
    ))
    return ok({'items': [complaint_json(c, db) for c in rows]})

@app.get('/api/admin/complaints')
def list_all(user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, 'admin')
    rows = list(db.scalars(select(ComplaintRow).order_by(ComplaintRow.created_at.desc())))
    return ok({'items': [complaint_json(c, db) for c in rows]})

@app.get('/api/complaints/{complaint_id}')
def complaint_detail(complaint_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    c = db.get(ComplaintRow, complaint_id)
    if not c: raise HTTPException(404, detail={'code': 'NOT_FOUND', 'message': 'Complaint not found.', 'details': {}})
    if user.role == 'citizen' and c.citizen_id != user.id: raise HTTPException(403, detail={'code': 'FORBIDDEN', 'message': 'Not your complaint.', 'details': {}})
    co_ids = [int(x) for x in (c.co_office_ids or '').split(',') if x.strip().isdigit()]
    if user.role == 'staff' and c.office_id != user.office_id and user.office_id not in co_ids:
        raise HTTPException(403, detail={'code': 'FORBIDDEN', 'message': 'Not assigned to your office.', 'details': {}})
    return ok({**complaint_json(c, db), 'location': str(c.location_id), 'confidence': c.confidence, 'keywords': [], 'responses': ([{'message': c.response_message, 'staff_name': user.name, 'created_at': iso(c.created_at)}] if c.response_message else []), 'history': [{'status': 'submitted', 'note': 'Complaint submitted.', 'by': complaint_json(c, db)['citizen_name'], 'at': iso(c.created_at)}]})

@app.patch('/api/complaints/{complaint_id}/status')
def update_status(complaint_id: int, data: StatusIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, 'staff', 'admin')
    c = db.get(ComplaintRow, complaint_id)
    if not c: raise HTTPException(404, detail={'code': 'NOT_FOUND', 'message': 'Complaint not found.', 'details': {}})
    co_ids = [int(x) for x in (c.co_office_ids or '').split(',') if x.strip().isdigit()]
    if user.role == 'staff' and c.office_id != user.office_id and user.office_id not in co_ids:
        raise HTTPException(403, detail={'code': 'FORBIDDEN', 'message': 'Complaint belongs to another office.', 'details': {}})
    legal = {'submitted': ['received', 'in_progress'], 'received': ['in_progress', 'resolved'], 'in_progress': ['resolved'], 'resolved': ['closed', 'in_progress'], 'closed': []}
    if data.status not in legal.get(c.status, []): raise HTTPException(409, detail={'code': 'INVALID_TRANSITION', 'message': 'This status change is not allowed.', 'details': {}})
    c.status = data.status; c.response_message = (data.response_message or '').strip() or None; db.commit()
    return ok({'message': 'Status updated.'})

# ─── Dashboard ────────────────────────────────────────────────────────────────

@app.get('/api/dashboard/summary')
def dashboard(user: User = Depends(current_user), db: Session = Depends(get_db)):
    q = select(ComplaintRow)
    if user.role == 'citizen': q = q.where(ComplaintRow.citizen_id == user.id)
    elif user.role == 'staff': q = q.where(ComplaintRow.office_id == user.office_id)
    rows = list(db.scalars(q.order_by(ComplaintRow.created_at.desc())))
    pending = sum(c.status in ('submitted', 'received') for c in rows)
    progress = sum(c.status == 'in_progress' for c in rows)
    solved = sum(c.status in ('resolved', 'closed') for c in rows)
    cats = {}
    for c in rows: cats[c.category_id] = cats.get(c.category_id, 0) + 1
    total = len(rows)
    return ok({'pending': pending, 'in_progress': progress, 'solved': solved, 'pending_delta': 0, 'in_progress_delta': 0, 'solved_delta': 0, 'service_level': round(solved * 100 / total, 1) if total else 0, 'service_target': 75, 'feedback_rating': 0, 'chart': {'labels': [], 'pending': [], 'in_progress': []}, 'recent': [complaint_json(c, db) for c in rows[:5]], 'categories': [{'name': f'Category {k}', 'percent': round(v * 100 / total) if total else 0} for k, v in sorted(cats.items(), key=lambda x: -x[1])[:4]]})

# ─── Reports ──────────────────────────────────────────────────────────────────

@app.get('/api/reports')
def reports(days: int = 30, office_id: Optional[int] = None, category_id: Optional[int] = None, user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, 'admin')
    q = select(ComplaintRow)
    if days > 0: q = q.where(ComplaintRow.created_at >= datetime.now(timezone.utc) - timedelta(days=days))
    if office_id is not None: q = q.where(ComplaintRow.office_id == office_id)
    if category_id is not None: q = q.where(ComplaintRow.category_id == category_id)
    rows = list(db.scalars(q.order_by(ComplaintRow.created_at.desc())))
    def tally(fn):
        d = {}
        for c in rows:
            label = fn(c); d[label] = d.get(label, 0) + 1
        return [{'label': k, 'count': v} for k, v in sorted(d.items())]
    closed = sum(c.status in ('resolved', 'closed') for c in rows)
    return ok({'total': len(rows), 'open': len(rows) - closed, 'resolved': closed, 'by_category': tally(lambda c: f'Category {c.category_id}'), 'by_office': tally(lambda c: f'Office {c.office_id}'), 'by_priority': tally(lambda c: c.priority), 'by_status': tally(lambda c: c.status), 'rows': [complaint_json(c, db) for c in rows]})

# ─── Admin: User management ───────────────────────────────────────────────────

@app.get('/api/admin/users')
def admin_users(user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, 'admin')
    return ok({'items': [user_json(u) for u in db.scalars(select(User).order_by(User.name))]})

@app.post('/api/admin/users')
def admin_create_user(data: AdminCreateUserIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """
    Admin-only: creates staff or admin accounts.
    - 'citizen' role is blocked here (citizens self-register via /api/auth/register).
    - Admin-created accounts skip email verification and are immediately active.
    - Least-privilege: an admin cannot create a role above 'admin'.
    """
    require_role(user, 'admin')
    if data.role not in ('staff', 'admin'):
        raise HTTPException(422, detail={'code': 'INVALID_ROLE', 'message': "Role must be 'staff' or 'admin'. Citizens self-register via the public form.", 'details': {}})
    if data.role == 'staff' and not data.office_id:
        raise HTTPException(422, detail={'code': 'VALIDATION_ERROR', 'message': 'office_id is required for staff accounts.', 'details': {}})
    email = str(data.email).lower().strip()
    if db.scalar(select(User).where(User.email == email)):
        raise HTTPException(409, detail={'code': 'EMAIL_EXISTS', 'message': 'An account with this email already exists.', 'details': {}})
    username = (data.username or email.split('@')[0]).lower().strip()
    if db.scalar(select(User).where(func.lower(User.username) == username)):
        if data.username:
            raise HTTPException(409, detail={'code': 'USERNAME_EXISTS', 'message': 'An account with this username already exists.', 'details': {}})
        username = f"{username}_{random.randint(100, 999)}"
    new_user = User(
        name=data.name.strip(),
        username=username,
        email=email,
        password_hash=hash_password(data.password),
        role=data.role,
        office_id=data.office_id if data.role == 'staff' else None,
        active=True,
        email_verified=True,  # Admin-created accounts are pre-verified
    )
    db.add(new_user); db.commit(); db.refresh(new_user)
    return ok({'id': new_user.id, 'message': f'{data.role.capitalize()} account created successfully.'})

@app.patch('/api/admin/users/{user_id}')
def set_active(user_id: int, active: bool, user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, 'admin')
    target = db.get(User, user_id)
    if not target: raise HTTPException(404, detail={'code': 'NOT_FOUND', 'message': 'User not found.', 'details': {}})
    if target.id == user.id: raise HTTPException(409, detail={'code': 'CONFLICT', 'message': 'You cannot deactivate your own account.', 'details': {}})
    target.active = active; db.commit()
    return ok({'message': 'User updated.'})

# ─── Admin: Offices ───────────────────────────────────────────────────────────

@app.get('/api/admin/offices')
def admin_offices(user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, 'admin')
    names = {1: 'City Engineering Office', 2: 'City Health Office', 3: 'City Environment and Natural Resources Office', 4: 'City Social Welfare and Development Office', 5: 'City Disaster Risk Reduction and Management Office', 6: 'City Public Safety Office', 7: "City Mayor's Office (General Concerns)"}
    items = []
    for oid, name in names.items():
        total = db.scalar(select(func.count()).select_from(ComplaintRow).where(ComplaintRow.office_id == oid)) or 0
        opened = db.scalar(select(func.count()).select_from(ComplaintRow).where(ComplaintRow.office_id == oid, ComplaintRow.status.notin_(['resolved', 'closed']))) or 0
        staff = db.scalar(select(func.count()).select_from(User).where(User.office_id == oid, User.role == 'staff')) or 0
        items.append({'id': oid, 'name': name, 'staff_count': staff, 'open_count': opened, 'total_count': total})
    return ok({'items': items})

# ─── Notifications ────────────────────────────────────────────────────────────

@app.get('/api/notifications')
def notifications(user: User = Depends(current_user), db: Session = Depends(get_db)):
    return ok({'items': []})
