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

try:
    from ml_classifier import classifier as ml_classifier
except ImportError:
    from BACKEND.ml_classifier import classifier as ml_classifier

UPLOAD_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'uploads')
os.makedirs(UPLOAD_DIR, exist_ok=True)

_env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.env')
load_dotenv(_env_path)
load_dotenv()
DATABASE_URL = os.getenv('DATABASE_URL', '').strip()
if DATABASE_URL.startswith('postgres://'):
    DATABASE_URL = DATABASE_URL.replace('postgres://', 'postgresql://', 1)
JWT_SECRET = os.getenv('JWT_SECRET', '').strip()
SMTP_HOST = (os.getenv('SMTP_HOST') or os.getenv('SMTP_SERVER') or 'smtp.gmail.com').strip()
SMTP_PORT = int(os.getenv('SMTP_PORT', '587'))
SMTP_USER = os.getenv('SMTP_USER', '').strip()
SMTP_PASS = os.getenv('SMTP_PASS', '').replace(' ', '').strip()
BREVO_API_KEY = os.getenv('BREVO_API_KEY', '').strip()
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
    candidates = [
        os.path.join(os.path.dirname(os.path.abspath(__file__)), 'citizensense.db'),
        os.path.join(os.getcwd(), 'citizensense.db'),
        os.path.join(os.getcwd(), 'BACKEND', 'citizensense.db'),
    ]
    sqlite_path = candidates[0]
    for p in candidates:
        if os.path.exists(p) and os.path.getsize(p) > 10000:
            sqlite_path = p
            break
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
    avatar_url: Mapped[Optional[str]] = mapped_column(String(255), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

class ComplaintRow(Base):
    __tablename__ = 'complaints_tbl'
    id: Mapped[int] = mapped_column('complaint_id', Integer, primary_key=True, autoincrement=True)
    citizen_id: Mapped[int] = mapped_column('user_id', Integer, index=True)
    office_id: Mapped[Optional[int]] = mapped_column(Integer, nullable=True, default=1)
    category_id: Mapped[Optional[int]] = mapped_column(Integer, nullable=True, default=1)
    location_id: Mapped[Optional[int]] = mapped_column(Integer, nullable=True, default=1)
    risk_level_id: Mapped[Optional[int]] = mapped_column(Integer, nullable=True, default=2)
    status_id: Mapped[Optional[int]] = mapped_column(Integer, nullable=True, default=1)
    title: Mapped[str] = mapped_column(String(200))
    description: Mapped[str] = mapped_column(Text)
    attachment_name: Mapped[Optional[str]] = mapped_column('attachment', String(255), nullable=True)
    date_resolved: Mapped[Optional[datetime]] = mapped_column(DateTime, nullable=True)
    status: Mapped[Optional[str]] = mapped_column(String(30), default='submitted', nullable=True)
    priority: Mapped[Optional[str]] = mapped_column(String(20), default='medium', nullable=True)
    sentiment: Mapped[Optional[str]] = mapped_column(String(20), default='neutral', nullable=True)
    confidence: Mapped[Optional[float]] = mapped_column(Float, default=0.0, nullable=True)
    response_message: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    co_office_ids: Mapped[Optional[str]] = mapped_column(String(100), default='', nullable=True)
    rating: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    feedback_comment: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    feedback_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column('date_submitted', DateTime, default=lambda: datetime.now(timezone.utc), index=True)

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

# ─── Notifications model ──────────────────────────────────────────────────────
# Stores in-app notifications per user.
# type: 'new_complaint' | 'status_update'
class Notification(Base):
    __tablename__ = 'citizensense_notifications'
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True, index=True)
    # recipient user id
    user_id: Mapped[int] = mapped_column(Integer, index=True)
    complaint_id: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    # type: 'new_complaint' | 'status_update'
    type: Mapped[str] = mapped_column(String(30), default='new_complaint')
    text: Mapped[str] = mapped_column(Text)
    is_read: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), index=True)

class ComplaintMessage(Base):
    __tablename__ = 'citizensense_complaint_messages'
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True, index=True)
    complaint_id: Mapped[int] = mapped_column(Integer, index=True)
    sender_id: Mapped[int] = mapped_column(Integer)
    sender_role: Mapped[str] = mapped_column(String(20))
    sender_name: Mapped[str] = mapped_column(String(160))
    message: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), index=True)

class ActivityLog(Base):
    __tablename__ = 'citizensense_activity_logs'
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True, index=True)
    actor_id: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    actor_name: Mapped[str] = mapped_column(String(160))
    actor_role: Mapped[str] = mapped_column(String(20))
    action: Mapped[str] = mapped_column(String(60))
    summary: Mapped[str] = mapped_column(Text)
    target_type: Mapped[Optional[str]] = mapped_column(String(40), nullable=True)
    target_id: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), index=True)

class Announcement(Base):
    __tablename__ = 'citizensense_announcements'
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True, index=True)
    title: Mapped[str] = mapped_column(String(200))
    content: Mapped[str] = mapped_column(Text)
    category: Mapped[str] = mapped_column(String(40), default='Announcement')
    status: Mapped[str] = mapped_column(String(20), default='approved')  # approved | pending | rejected
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_by_id: Mapped[int] = mapped_column(Integer, index=True)
    created_by_name: Mapped[str] = mapped_column(String(160))
    created_by_role: Mapped[str] = mapped_column(String(20), default='admin')
    reviewed_by_name: Mapped[Optional[str]] = mapped_column(String(160), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), index=True)

Base.metadata.create_all(bind=engine)

def _run_migrations(db_engine):
    try:
        from sqlalchemy import text
        alters = [
            f'ALTER TABLE complaints_tbl ADD COLUMN {col} {col_type}'
            for col, col_type in [
                ('co_office_ids', 'VARCHAR(100)'),
                ('attachment', 'VARCHAR(255)'),
                ('response_message', 'TEXT'),
                ('sentiment', "VARCHAR(20) DEFAULT 'neutral'"),
                ('confidence', 'FLOAT DEFAULT 0.0'),
                ('status', "VARCHAR(30) DEFAULT 'submitted'"),
                ('priority', "VARCHAR(20) DEFAULT 'medium'"),
                ('rating', 'INTEGER'),
                ('feedback_comment', 'TEXT'),
                ('feedback_at', 'TIMESTAMP'),
            ]
        ] + ['ALTER TABLE citizensense_users ADD COLUMN avatar_url VARCHAR(255)']
        for stmt in alters:
            try:
                with db_engine.begin() as conn:
                    conn.execute(text(stmt))
            except Exception:
                pass
    except Exception as e:
        print(f'Migration note: {e}')

_run_migrations(engine)

def _log_activity(db: Session, user: Optional['User'], action: str, summary: str, target_type: Optional[str] = None, target_id: Optional[int] = None):
    """Record a human-readable activity log entry for administrators."""
    try:
        entry = ActivityLog(
            actor_id=user.id if user else None,
            actor_name=user.name if user else 'System',
            actor_role=user.role if user else 'system',
            action=action,
            summary=summary,
            target_type=target_type,
            target_id=target_id,
        )
        db.add(entry)
        db.commit()
    except Exception as e:
        print(f'[activity_log] error: {e}')

# ─── Notification helpers ─────────────────────────────────────────────────────

def _push_notification(db: Session, user_id: int, complaint_id: int, notif_type: str, text: str):
    """Insert a single in-app notification row."""
    try:
        n = Notification(
            user_id=user_id,
            complaint_id=complaint_id,
            type=notif_type,
            text=text,
            is_read=False,
        )
        db.add(n)
    except Exception as e:
        print(f'[notify] push failed: {e}')

def _notify_new_complaint(db: Session, complaint: 'ComplaintRow', submitter: 'User'):
    """
    When a citizen submits a complaint:
     - Notify all admins
     - Notify all staff of the target office (and co-offices)
    """
    try:
        label = complaint.title[:60]
        text = f"New complaint: \"{label}\" submitted by {submitter.name}."

        # All admins
        admins = list(db.scalars(select(User).where(User.role == 'admin', User.active == True)))
        for a in admins:
            _push_notification(db, a.id, complaint.id, 'new_complaint', text)

        # Staff of primary office
        office_ids = {complaint.office_id}
        co_ids_raw = (complaint.co_office_ids or '').split(',')
        for x in co_ids_raw:
            x = x.strip()
            if x.isdigit():
                office_ids.add(int(x))

        staff_list = list(db.scalars(
            select(User).where(User.role == 'staff', User.active == True, User.office_id.in_(office_ids))
        ))
        for s in staff_list:
            _push_notification(db, s.id, complaint.id, 'new_complaint', text)

        db.commit()
    except Exception as e:
        print(f'[notify] new_complaint error: {e}')

def _notify_status_change(db: Session, complaint: 'ComplaintRow', new_status: str, changed_by: 'User'):
    """
    When a complaint status changes to in_progress or resolved:
     - Notify the citizen who submitted it
    """
    try:
        status_labels = {
            'received': 'has been received',
            'in_progress': 'is now being processed',
            'resolved': 'has been resolved',
            'closed': 'has been closed',
        }
        label = status_labels.get(new_status, f'is now {new_status}')
        text = f"Your complaint \"{complaint.title[:60]}\" {label}."
        if complaint.response_message:
            text += f" Response: {complaint.response_message[:100]}"

        _push_notification(db, complaint.citizen_id, complaint.id, 'status_update', text)
        db.commit()
    except Exception as e:
        print(f'[notify] status_change error: {e}')

app = FastAPI(title='CBR CitizenSense API', version='0.2.0')

app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=r'.*',
    allow_credentials=True,
    allow_methods=['*'],
    allow_headers=['*'],
)

@app.exception_handler(HTTPException)
async def api_error_handler(request: Request, exc: HTTPException):
    detail = exc.detail if isinstance(exc.detail, dict) else {'code': 'REQUEST_ERROR', 'message': str(exc.detail), 'details': {}}
    return JSONResponse(status_code=exc.status_code, content={'error': {'code': detail.get('code', 'REQUEST_ERROR'), 'message': detail.get('message', 'Request failed.'), 'details': detail.get('details', {})}})

@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    import traceback
    err_tb = traceback.format_exc()
    print(f'[GLOBAL 500] {exc}\n{err_tb}')
    return JSONResponse(status_code=500, content={'error': {'code': 'INTERNAL_ERROR', 'message': str(exc), 'details': {'traceback': err_tb}}})

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
            ann_count = db.scalar(select(func.count(Announcement.id)))
            if not ann_count:
                db.add_all([
                    Announcement(
                        title='Welcome to Cabadbaran CitizenSense 2.0',
                        content='Submit community concerns anytime—our upgraded AI classifier routes them directly to the right Cabadbaran City office.',
                        category='Announcement',
                        status='approved',
                        is_active=True,
                        created_by_id=1,
                        created_by_name='Admin One (System Lead)',
                        created_by_role='admin',
                        reviewed_by_name='Admin One (System Lead)',
                    ),
                    Announcement(
                        title='Cabadbaran City Clean & Green Drive',
                        content='Report uncollected waste or clogged drainage early so CENRO and CDRRMO can respond before heavy rains.',
                        category='Promotion',
                        status='approved',
                        is_active=True,
                        created_by_id=1,
                        created_by_name='Admin One (System Lead)',
                        created_by_role='admin',
                        reviewed_by_name='Admin One (System Lead)',
                    ),
                ])
                db.commit()
    except Exception as e:
        print(f'Seed check skipped: {e}')

seed_defaults()

def seed_complaints_if_empty():
    try:
        with SessionLocal() as db:
            count = db.scalar(select(func.count(ComplaintRow.id)))
            if count == 0:
                import sqlite3
                sqlite_candidates = [
                    os.path.join(os.path.dirname(os.path.abspath(__file__)), 'citizensense.db'),
                    os.path.join(os.getcwd(), 'citizensense.db'),
                    os.path.join(os.getcwd(), 'BACKEND', 'citizensense.db'),
                ]
                for sp in sqlite_candidates:
                    if os.path.exists(sp) and os.path.getsize(sp) > 10000:
                        sconn = sqlite3.connect(sp)
                        scur = sconn.cursor()
                        scur.execute("SELECT complaint_id, user_id, office_id, category_id, location_id, risk_level_id, status_id, status, priority, title, description, attachment, response_message, co_office_ids, sentiment, confidence FROM complaints_tbl")
                        rows = scur.fetchall()
                        sconn.close()
                        if rows:
                            print(f'Auto-seeding {len(rows)} complaints into empty complaints_tbl...')
                            for r in rows:
                                c = ComplaintRow(
                                    id=r[0],
                                    citizen_id=r[1],
                                    office_id=r[2],
                                    category_id=r[3],
                                    location_id=r[4],
                                    risk_level_id=r[5],
                                    status_id=r[6],
                                    status=r[7],
                                    priority=r[8],
                                    title=r[9],
                                    description=r[10],
                                    attachment_name=r[11],
                                    response_message=r[12],
                                    co_office_ids=r[13],
                                    sentiment=r[14],
                                    confidence=r[15]
                                )
                                db.add(c)
                            db.commit()
                            print('Successfully auto-seeded complaints into complaints_tbl!')
                        break
    except Exception as e:
        print(f'Auto-seed complaints note: {e}')

seed_complaints_if_empty()

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
    """Send a plain-text email via Brevo HTTP API (if BREVO_API_KEY is set) or SMTP.
    If neither is configured or placeholder values are used, prints OTP to console.
    """
    if BREVO_API_KEY:
        try:
            import urllib.request
            from email.utils import parseaddr
            sender_name, sender_email = parseaddr(APP_EMAIL_FROM or SMTP_USER or 'noreply@citizensense.ph')
            if not sender_email:
                sender_email = 'noreply@citizensense.ph'
            payload = json.dumps({
                'sender': {'name': sender_name or 'CBR CitizenSense', 'email': sender_email},
                'to': [{'email': to}],
                'subject': subject,
                'textContent': body,
            }).encode('utf-8')
            req = urllib.request.Request(
                'https://api.brevo.com/v3/smtp/email',
                data=payload,
                headers={
                    'accept': 'application/json',
                    'api-key': BREVO_API_KEY,
                    'content-type': 'application/json',
                },
                method='POST',
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                print(f'[BREVO API] Email sent to {to} (status {resp.status})')
                return
        except Exception as e:
            print(f'\n[BREVO API ERROR] Could not send email via Brevo API ({e}). Trying SMTP fallback...')

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

def user_json(u):
    return {
        'id': u.id,
        'name': u.name,
        'username': u.username or '',
        'email': u.email,
        'role': u.role,
        'office_id': u.office_id,
        'active': u.active,
        'avatar_url': u.avatar_url,
    }

def iso(dt):
    if dt is None:
        return datetime.now(timezone.utc).isoformat()
    if hasattr(dt, 'isoformat'):
        return dt.isoformat()
    return str(dt)

def complaint_json(c: ComplaintRow, db: Session, user_obj=None, mask_citizen: bool = False):
    u = user_obj if user_obj is not None else db.get(User, c.citizen_id)
    co_ids = [int(x) for x in (c.co_office_ids or '').split(',') if x.strip().isdigit()]
    return {
        'id': c.id,
        'title': c.title,
        'description': c.description,
        'category_id': c.category_id or 1,
        'office_id': c.office_id or 1,
        'co_office_ids': co_ids,
        'location_id': c.location_id or 1,
        'status': c.status or 'submitted',
        'priority': c.priority or 'medium',
        'sentiment': c.sentiment or 'neutral',
        'created_at': iso(c.created_at),
        'citizen_name': 'Anonymous Citizen' if mask_citizen else (u.name if u else 'Citizen'),
        'citizen_email': '' if mask_citizen else (u.email if u else ''),
        'attachment_name': c.attachment_name,
        'attachment_url': f'/api/complaints/{c.id}/attachment' if c.attachment_name else None,
        'rating': c.rating,
        'feedback_comment': c.feedback_comment,
        'feedback_at': iso(c.feedback_at) if c.feedback_at else None,
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
class MessageIn(BaseModel): message: str = Field(min_length=1, max_length=1000)
class FeedbackIn(BaseModel): rating: int = Field(ge=1, le=5); comment: Optional[str] = Field(default=None, max_length=500)
class SetActiveIn(BaseModel): active: bool
class ProfileIn(BaseModel): name: str = Field(min_length=2, max_length=160)
class EmailChangeRequestIn(BaseModel): current_password: str; new_email: EmailStr
class EmailChangeConfirmIn(BaseModel): new_email: EmailStr; code: str = Field(min_length=6, max_length=6)

# Admin-only schema for creating staff / admin accounts
class AdminCreateUserIn(BaseModel):
    name: str = Field(min_length=2, max_length=160)
    username: Optional[str] = Field(default=None, max_length=50)
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)
    role: str  # 'staff' or 'admin'
    office_id: Optional[int] = None  # required when role == 'staff'

class AdminUpdateUserIn(BaseModel):
    name: Optional[str] = Field(default=None, min_length=2, max_length=160)
    office_id: Optional[int] = None
    active: Optional[bool] = None
    password: Optional[str] = Field(default=None, min_length=8, max_length=128)

class AnnouncementIn(BaseModel):
    title: str = Field(min_length=3, max_length=200)
    content: str = Field(min_length=5, max_length=2000)
    category: str = Field(default='Announcement', max_length=40)

class AnnouncementUpdateIn(BaseModel):
    title: Optional[str] = Field(default=None, min_length=3, max_length=200)
    content: Optional[str] = Field(default=None, min_length=5, max_length=2000)
    category: Optional[str] = Field(default=None, max_length=40)
    status: Optional[str] = None  # 'approved' | 'rejected' | 'pending'
    is_active: Optional[bool] = None

# ─── Health ───────────────────────────────────────────────────────────────────

@app.get('/')
def home(): return {'message': 'CBR CitizenSense API is running', 'version': '2.1.0-dashboard-fix', 'docs': '/docs'}

@app.get('/health')
@app.get('/api/health')
@app.get('/api/health/db')
def health(db: Session = Depends(get_db)):
    db.execute(select(1))
    c_count = db.scalar(select(func.count(ComplaintRow.id)))
    u_count = db.scalar(select(func.count(User.id)))
    return {
        'database': 'connected',
        'dialect': engine.dialect.name,
        'status': 'ok',
        'complaints_count': c_count,
        'users_count': u_count,
    }

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
    _log_activity(db, user, 'login', f'{user.name} ({user.role}) logged in.', 'user', user.id)
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
    _log_activity(db, user, 'change_password', f'{user.name} ({user.role}) changed their password.', 'user', user.id)
    return ok({'message': 'Password updated.'})

@app.get('/api/auth/me')
def get_me(user: User = Depends(current_user)):
    return ok({'user': user_json(user)})

@app.patch('/api/auth/profile')
def update_profile(data: ProfileIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    user.name = data.name.strip()
    db.commit()
    _log_activity(db, user, 'update_profile', f'{user.name} ({user.role}) updated their display name.', 'user', user.id)
    return ok({'user': user_json(user)})

@app.post('/api/auth/avatar')
async def upload_avatar(request: Request, user: User = Depends(current_user), db: Session = Depends(get_db)):
    form = await request.form()
    file_field = form.get('avatar')
    if not file_field or not hasattr(file_field, 'filename') or not file_field.filename:
        raise HTTPException(422, detail={'code': 'VALIDATION_ERROR', 'message': 'Please select an image file.'})
    ext = os.path.splitext(file_field.filename)[1].lower()
    if ext not in ('.jpg', '.jpeg', '.png', '.webp'):
        raise HTTPException(422, detail={'code': 'VALIDATION_ERROR', 'message': 'Only JPG, PNG, or WEBP images are allowed.'})
    content = await file_field.read()
    if len(content) > 3 * 1024 * 1024:
        raise HTTPException(422, detail={'code': 'VALIDATION_ERROR', 'message': 'Image must be under 3MB.'})
    avatar_dir = os.path.join(UPLOAD_DIR, 'avatars')
    os.makedirs(avatar_dir, exist_ok=True)
    fname = f'user_{user.id}_{int(time.time())}{ext}'
    with open(os.path.join(avatar_dir, fname), 'wb') as f:
        f.write(content)
    user.avatar_url = f'/api/auth/avatar/{user.id}?v={int(time.time())}'
    db.commit()
    _log_activity(db, user, 'update_avatar', f'{user.name} ({user.role}) updated their profile photo/logo.', 'user', user.id)
    return ok({'user': user_json(user)})

@app.get('/api/auth/avatar/{user_id}')
def get_avatar(user_id: int, db: Session = Depends(get_db)):
    avatar_dir = os.path.join(UPLOAD_DIR, 'avatars')
    if not os.path.exists(avatar_dir):
        raise HTTPException(404, detail={'code': 'NOT_FOUND', 'message': 'Avatar not found.'})
    matches = sorted([f for f in os.listdir(avatar_dir) if f.startswith(f'user_{user_id}_')], reverse=True)
    if not matches:
        raise HTTPException(404, detail={'code': 'NOT_FOUND', 'message': 'Avatar not found.'})
    path = os.path.join(avatar_dir, matches[0])
    mime, _ = mimetypes.guess_type(path)
    return FileResponse(path, media_type=mime or 'image/png')

@app.post('/api/auth/email-change/request')
def request_email_change(data: EmailChangeRequestIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    if not verify_password(data.current_password, user.password_hash):
        raise HTTPException(400, detail={'code': 'PASSWORD_MISMATCH', 'message': 'Current password is incorrect.'})
    new_email = str(data.new_email).lower().strip()
    if new_email == user.email.lower():
        raise HTTPException(422, detail={'code': 'VALIDATION_ERROR', 'message': 'New email is the same as your current email.'})
    if db.scalar(select(User).where(User.email == new_email)):
        raise HTTPException(409, detail={'code': 'EMAIL_EXISTS', 'message': 'This email is already in use by another account.'})
    code = _issue_otp(db, new_email, 'change_email')
    _send_email(
        to=new_email,
        subject='CBR CitizenSense – Confirm your new email address',
        body=(
            f'Hi {user.name},\n\n'
            f'You requested to change your CitizenSense email address to {new_email}.\n\n'
            f'Your verification code is: {code}\n\n'
            f'This code expires in {OTP_TTL_MINUTES} minutes.\n'
        ),
    )
    return ok({'message': f'Verification code sent to {new_email}.'})

@app.post('/api/auth/email-change/confirm')
def confirm_email_change(data: EmailChangeConfirmIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    new_email = str(data.new_email).lower().strip()
    if db.scalar(select(User).where(User.email == new_email, User.id != user.id)):
        raise HTTPException(409, detail={'code': 'EMAIL_EXISTS', 'message': 'This email is already in use.'})
    if not _verify_otp(db, new_email, 'change_email', data.code.strip()):
        raise HTTPException(400, detail={'code': 'INVALID_CODE', 'message': 'The verification code is incorrect or has expired.'})
    old_email = user.email
    user.email = new_email
    db.commit()
    _log_activity(db, user, 'change_email', f'{user.name} ({user.role}) changed email from {old_email} to {new_email}.', 'user', user.id)
    return ok({'user': user_json(user), 'message': 'Email address updated successfully.'})

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
    Hybrid TF-IDF + Multinomial Naive Bayes + Word-Boundary NLP classifier.
    """
    return ml_classifier.classify(description, category_id)


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
    risk_map = {'low': 1, 'medium': 2, 'high': 3, 'critical': 4}
    r_id = risk_map.get(nlp.get('priority', 'medium'), 2)
    c = ComplaintRow(
        citizen_id=user.id,
        title=title,
        description=description,
        category_id=category_id,
        office_id=office_id,
        co_office_ids=co_ids_str,
        location_id=location_id,
        status='submitted',
        status_id=1,
        risk_level_id=r_id,
        priority=nlp['priority'],
        sentiment=nlp['sentiment'],
        confidence=nlp['confidence'],
        attachment_name=attachment_filename
    )
    db.add(c); db.commit(); db.refresh(c)
    # ── Notify admins + assigned office staff about new complaint ──
    _notify_new_complaint(db, c, user)
    _log_activity(db, user, 'submit_complaint', f'{user.name} submitted complaint #{c.id}: "{c.title[:60]}" ({c.priority} priority).', 'complaint', c.id)
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
    try:
        rows = list(db.scalars(select(ComplaintRow).where(ComplaintRow.citizen_id == user.id).order_by(ComplaintRow.created_at.desc())))
        return ok({'items': [complaint_json(c, db) for c in rows]})
    except Exception as e:
        print(f'Error listing complaints: {e}')
        return ok({'items': []})

@app.get('/api/staff/complaints')
def list_staff(user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, 'staff')
    user_oid = str(user.office_id)
    rows = list(db.scalars(
        select(ComplaintRow).where(
            (ComplaintRow.office_id == user.office_id) |
            (ComplaintRow.co_office_ids.like(f'%{user_oid}%'))
        ).order_by(ComplaintRow.created_at.desc()).limit(2030)
    ))
    users_cache = {u.id: u for u in db.scalars(select(User)).all()}
    return ok({'items': [complaint_json(c, db, users_cache.get(c.citizen_id), mask_citizen=True) for c in rows]})

@app.get('/api/admin/complaints')
def list_all(user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, 'admin')
    rows = list(db.scalars(select(ComplaintRow).order_by(ComplaintRow.created_at.desc()).limit(2030)))
    users_cache = {u.id: u for u in db.scalars(select(User)).all()}
    return ok({'items': [complaint_json(c, db, users_cache.get(c.citizen_id)) for c in rows]})

@app.get('/api/complaints/export-csv')
def export_my_complaints_csv(
    token: Optional[str] = None,
    authorization: Optional[str] = Header(default=None),
    db: Session = Depends(get_db),
):
    """Allow citizens to download a CSV of their own complaints (and staff for their office, admin for all)."""
    auth_header = authorization
    if not auth_header and token:
        auth_header = f'Bearer {token.strip()}'
    user = current_user(authorization=auth_header, db=db)

    import io, csv as csv_mod
    q = select(ComplaintRow)
    if user.role == 'citizen':
        q = q.where(ComplaintRow.citizen_id == user.id)
    elif user.role == 'staff':
        user_oid = str(user.office_id)
        q = q.where((ComplaintRow.office_id == user.office_id) | (ComplaintRow.co_office_ids.like(f'%{user_oid}%')))
    rows = list(db.scalars(q.order_by(ComplaintRow.created_at.desc()).limit(2030)))

    output = io.StringIO()
    w = csv_mod.writer(output)
    w.writerow(['CABADBARAN CITIZENSENSE — MY COMPLAINTS EXPORT'])
    w.writerow(['Account:', f'{user.name} ({user.email})'])
    w.writerow(['Generated At:', datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')])
    w.writerow(['Total Complaints:', len(rows)])
    w.writerow([])
    w.writerow(['ID', 'Date Submitted', 'Complaint Type', 'Description', 'Assigned Office', 'Status', 'Priority', 'Sentiment', 'Date Resolved', 'Response Message', 'My Rating', 'My Comment'])
    for c in rows:
        w.writerow([
            c.id,
            c.created_at.strftime('%Y-%m-%d %H:%M') if c.created_at else '',
            c.title or '',
            (c.description or '').replace('\n', ' ')[:300],
            _OFFICE_NAMES.get(c.office_id, f'Office {c.office_id}'),
            (c.status or '').replace('_', ' ').title(),
            (c.priority or '').capitalize(),
            (c.sentiment or '').capitalize(),
            c.date_resolved.strftime('%Y-%m-%d %H:%M') if c.date_resolved else '',
            (c.response_message or '').replace('\n', ' ')[:300],
            c.rating if c.rating is not None else '',
            (c.feedback_comment or '').replace('\n', ' ')[:300],
        ])

    output.seek(0)
    _log_activity(db, user, 'export_csv', f'{user.name} ({user.role}) exported {len(rows)} complaints to CSV.', 'user', user.id)
    filename = f'My_Complaints_{datetime.now().strftime("%Y%m%d_%H%M")}.csv'
    from fastapi.responses import StreamingResponse
    return StreamingResponse(
        iter([output.getvalue()]),
        media_type='text/csv',
        headers={'Content-Disposition': f'attachment; filename="{filename}"'},
    )

@app.get('/api/complaints/{complaint_id}')
def complaint_detail(complaint_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    c = db.get(ComplaintRow, complaint_id)
    if not c: raise HTTPException(404, detail={'code': 'NOT_FOUND', 'message': 'Complaint not found.', 'details': {}})
    if user.role == 'citizen' and c.citizen_id != user.id: raise HTTPException(403, detail={'code': 'FORBIDDEN', 'message': 'Not your complaint.', 'details': {}})
    co_ids = [int(x) for x in (c.co_office_ids or '').split(',') if x.strip().isdigit()]
    if user.role == 'staff' and c.office_id != user.office_id and user.office_id not in co_ids:
        raise HTTPException(403, detail={'code': 'FORBIDDEN', 'message': 'Not assigned to your office.', 'details': {}})
    mask_citizen = (user.role == 'staff')
    cj = complaint_json(c, db, mask_citizen=mask_citizen)
    msgs = list(db.scalars(
        select(ComplaintMessage).where(ComplaintMessage.complaint_id == c.id).order_by(ComplaintMessage.created_at.asc())
    ))
    msg_list = [
        {
            'id': m.id,
            'sender_role': m.sender_role,
            'sender_name': 'Anonymous Citizen' if (mask_citizen and m.sender_role == 'citizen') else m.sender_name,
            'message': m.message,
            'created_at': iso(m.created_at),
        }
        for m in msgs
    ]
    return ok({
        **cj,
        'location': str(c.location_id),
        'confidence': c.confidence,
        'keywords': [],
        'responses': ([{'message': c.response_message, 'staff_name': _OFFICE_NAMES.get(c.office_id, 'Assigned Office'), 'created_at': iso(c.date_resolved or c.created_at)}] if c.response_message else []),
        'messages': msg_list,
        'history': [{'status': 'submitted', 'note': 'Complaint submitted.', 'by': cj['citizen_name'], 'at': iso(c.created_at)}],
    })

@app.get('/api/complaints/{complaint_id}/messages')
def list_complaint_messages(complaint_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    c = db.get(ComplaintRow, complaint_id)
    if not c: raise HTTPException(404, detail={'code': 'NOT_FOUND', 'message': 'Complaint not found.'})
    if user.role == 'citizen' and c.citizen_id != user.id:
        raise HTTPException(403, detail={'code': 'FORBIDDEN', 'message': 'Not your complaint.'})
    co_ids = [int(x) for x in (c.co_office_ids or '').split(',') if x.strip().isdigit()]
    if user.role == 'staff' and c.office_id != user.office_id and user.office_id not in co_ids:
        raise HTTPException(403, detail={'code': 'FORBIDDEN', 'message': 'Not assigned to your office.'})
    mask_citizen = (user.role == 'staff')
    msgs = list(db.scalars(
        select(ComplaintMessage).where(ComplaintMessage.complaint_id == c.id).order_by(ComplaintMessage.created_at.asc())
    ))
    return ok({'items': [
        {
            'id': m.id,
            'sender_role': m.sender_role,
            'sender_name': 'Anonymous Citizen' if (mask_citizen and m.sender_role == 'citizen') else m.sender_name,
            'message': m.message,
            'created_at': iso(m.created_at),
        }
        for m in msgs
    ]})

@app.post('/api/complaints/{complaint_id}/messages')
def post_complaint_message(complaint_id: int, data: MessageIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    c = db.get(ComplaintRow, complaint_id)
    if not c: raise HTTPException(404, detail={'code': 'NOT_FOUND', 'message': 'Complaint not found.'})
    if user.role == 'citizen' and c.citizen_id != user.id:
        raise HTTPException(403, detail={'code': 'FORBIDDEN', 'message': 'Not your complaint.'})
    co_ids = [int(x) for x in (c.co_office_ids or '').split(',') if x.strip().isdigit()]
    if user.role == 'staff' and c.office_id != user.office_id and user.office_id not in co_ids:
        raise HTTPException(403, detail={'code': 'FORBIDDEN', 'message': 'Not assigned to your office.'})
    text = data.message.strip()
    m = ComplaintMessage(
        complaint_id=c.id,
        sender_id=user.id,
        sender_role=user.role,
        sender_name=user.name,
        message=text,
    )
    db.add(m)
    db.commit()
    db.refresh(m)

    # Notify the other party
    if user.role in ('staff', 'admin'):
        _push_notification(db, c.citizen_id, c.id, 'status_update', f'Follow-up question on complaint #{c.id}: "{text[:80]}"')
        db.commit()
    else:
        office_ids = {c.office_id} | set(co_ids)
        for s in db.scalars(select(User).where(User.role == 'staff', User.active == True, User.office_id.in_(office_ids))):
            _push_notification(db, s.id, c.id, 'new_complaint', f'Citizen replied on complaint #{c.id}: "{text[:80]}"')
        for a in db.scalars(select(User).where(User.role == 'admin', User.active == True)):
            _push_notification(db, a.id, c.id, 'new_complaint', f'Citizen replied on complaint #{c.id}: "{text[:80]}"')
        db.commit()

    _log_activity(db, user, 'complaint_message', f'{user.name} ({user.role}) posted a message on complaint #{c.id}.', 'complaint', c.id)
    return ok({
        'id': m.id,
        'sender_role': m.sender_role,
        'sender_name': 'Anonymous Citizen' if (user.role == 'staff' and m.sender_role == 'citizen') else m.sender_name,
        'message': m.message,
        'created_at': iso(m.created_at),
    })

@app.post('/api/complaints/{complaint_id}/feedback')
def submit_complaint_feedback(complaint_id: int, data: FeedbackIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, 'citizen')
    c = db.get(ComplaintRow, complaint_id)
    if not c: raise HTTPException(404, detail={'code': 'NOT_FOUND', 'message': 'Complaint not found.'})
    if c.citizen_id != user.id:
        raise HTTPException(403, detail={'code': 'FORBIDDEN', 'message': 'You can only rate your own complaint.'})
    if c.status not in ('resolved', 'closed') and not c.response_message:
        raise HTTPException(409, detail={'code': 'INVALID_STATE', 'message': 'You can rate once the office has responded or resolved your complaint.'})
    c.rating = data.rating
    c.feedback_comment = (data.comment or '').strip() or None
    c.feedback_at = datetime.now(timezone.utc)
    db.commit()

    co_ids = [int(x) for x in (c.co_office_ids or '').split(',') if x.strip().isdigit()]
    office_ids = {c.office_id} | set(co_ids)
    for s in db.scalars(select(User).where(User.role == 'staff', User.active == True, User.office_id.in_(office_ids))):
        _push_notification(db, s.id, c.id, 'status_update', f'Citizen rated complaint #{c.id} response: {data.rating}/5 stars.')
    for a in db.scalars(select(User).where(User.role == 'admin', User.active == True)):
        _push_notification(db, a.id, c.id, 'status_update', f'{user.name} rated complaint #{c.id}: {data.rating}/5 stars.')
    db.commit()

    _log_activity(db, user, 'feedback_rating', f'{user.name} rated complaint #{c.id} ({data.rating}/5 stars).', 'complaint', c.id)
    return ok({'message': 'Thank you for your feedback!', 'rating': c.rating, 'feedback_comment': c.feedback_comment})

@app.patch('/api/complaints/{complaint_id}/status')
def update_status(complaint_id: int, data: StatusIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, 'staff', 'admin')
    c = db.get(ComplaintRow, complaint_id)
    if not c: raise HTTPException(404, detail={'code': 'NOT_FOUND', 'message': 'Complaint not found.', 'details': {}})
    co_ids = [int(x) for x in (c.co_office_ids or '').split(',') if x.strip().isdigit()]
    if user.role == 'staff' and c.office_id != user.office_id and user.office_id not in co_ids:
        raise HTTPException(403, detail={'code': 'FORBIDDEN', 'message': 'Complaint belongs to another office.', 'details': {}})
    legal = {
        'submitted': ['received', 'in_progress', 'closed'],
        'received': ['in_progress', 'resolved', 'closed'],
        'in_progress': ['resolved', 'closed'],
        'resolved': ['closed', 'in_progress'],
        'closed': [],
    }
    if data.status not in legal.get(c.status, []): raise HTTPException(409, detail={'code': 'INVALID_TRANSITION', 'message': 'This status change is not allowed.', 'details': {}})
    status_map = {'submitted': 1, 'received': 1, 'in_progress': 2, 'resolved': 3, 'closed': 4}
    old_status = c.status
    c.status = data.status
    c.status_id = status_map.get(data.status, c.status_id)
    if data.status in ('resolved', 'closed'):
        c.date_resolved = datetime.now(timezone.utc)
    if data.response_message and data.response_message.strip():
        c.response_message = data.response_message.strip()
    db.commit()
    # ── Notify the citizen that their complaint status changed ──
    if data.status in ('received', 'in_progress', 'resolved', 'closed'):
        _notify_status_change(db, c, data.status, user)
    _log_activity(db, user, 'update_status', f'{user.name} ({user.role}) changed complaint #{c.id} from {old_status} to {data.status}.', 'complaint', c.id)
    return ok({'message': 'Status updated.'})

# ─── Dashboard ────────────────────────────────────────────────────────────────

@app.get('/api/dashboard/summary')
def dashboard(user: User = Depends(current_user), db: Session = Depends(get_db)):
    try:
        q = select(ComplaintRow)
        if user.role == 'citizen': q = q.where(ComplaintRow.citizen_id == user.id)
        elif user.role == 'staff': q = q.where(ComplaintRow.office_id == user.office_id)
        rows = list(db.scalars(q.order_by(ComplaintRow.created_at.desc()).limit(2030)))
        pending = sum(c.status in ('submitted', 'received') for c in rows)
        progress = sum(c.status == 'in_progress' for c in rows)
        solved = sum(c.status in ('resolved', 'closed') for c in rows)
        total = len(rows)

        office_names = {
            1: "City Engineering",
            2: "City Health Office",
            3: "CENRO Environment",
            4: "Social Welfare (CSWDO)",
            5: "Disaster Risk (CDRRMO)",
            6: "Public Safety / Police",
            7: "Mayor's Office",
        }
        cats = {}
        for c in rows:
            name = office_names.get(c.office_id, f"Office {c.office_id}")
            cats[name] = cats.get(name, 0) + 1

        now = datetime.now(timezone.utc)
        day_dates = [(now - timedelta(days=i)).date() for i in range(13, -1, -1)]
        labels = [d.strftime('%b %d') for d in day_dates]

        pending_by_day = {d: 0 for d in day_dates}
        progress_by_day = {d: 0 for d in day_dates}
        for c in rows:
            if c.created_at is None:
                continue
            c_date = c.created_at.date() if hasattr(c.created_at, 'date') else None
            if c_date in pending_by_day:
                if c.status in ('submitted', 'received'):
                    pending_by_day[c_date] += 1
                elif c.status == 'in_progress':
                    progress_by_day[c_date] += 1

        pending_trend = [pending_by_day[d] for d in day_dates]
        progress_trend = [progress_by_day[d] for d in day_dates]

        # Real feedback rating from actual citizen ratings
        rated_values = [c.rating for c in rows if c.rating is not None]
        avg_rating = round(sum(rated_values) / len(rated_values), 1) if rated_values else 0.0

        # Real 7-day vs prior 7-day deltas
        cutoff_7 = (now - timedelta(days=7)).date()
        cutoff_14 = (now - timedelta(days=14)).date()
        def _delta(statuses):
            cur_cnt = sum(1 for c in rows if c.status in statuses and c.created_at and c.created_at.date() >= cutoff_7)
            prev_cnt = sum(1 for c in rows if c.status in statuses and c.created_at and cutoff_14 <= c.created_at.date() < cutoff_7)
            if prev_cnt == 0:
                return 0
            return round((cur_cnt - prev_cnt) * 100 / prev_cnt)

        mask_citizen = (user.role == 'staff')
        users_cache = {u.id: u for u in db.scalars(select(User)).all()}
        return ok({
            'pending': pending,
            'in_progress': progress,
            'solved': solved,
            'pending_delta': _delta(('submitted', 'received')),
            'in_progress_delta': _delta(('in_progress',)),
            'solved_delta': _delta(('resolved', 'closed')),
            'service_level': round(solved * 100 / total, 1) if total else 0.0,
            'service_target': 75,
            'feedback_rating': avg_rating,
            'chart': {
                'labels': labels,
                'pending': pending_trend,
                'in_progress': progress_trend
            },
            'recent': [complaint_json(c, db, users_cache.get(c.citizen_id), mask_citizen=mask_citizen) for c in rows[:5]],
            'categories': [{'name': k, 'percent': round(v * 100 / total) if total else 0} for k, v in sorted(cats.items(), key=lambda x: -x[1])[:4]]
        })
    except Exception as e:
        print(f'Dashboard summary error: {e}')
        return ok({'pending': 0, 'in_progress': 0, 'solved': 0, 'pending_delta': 0, 'in_progress_delta': 0, 'solved_delta': 0, 'service_level': 0, 'service_target': 75, 'feedback_rating': 0, 'chart': {'labels': [], 'pending': [], 'in_progress': []}, 'recent': [], 'categories': []})

# ─── Reports ──────────────────────────────────────────────────────────────────

@app.get('/api/reports')
def reports(days: int = 30, office_id: Optional[int] = None, category_id: Optional[int] = None, user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, 'admin')
    q = select(ComplaintRow)
    if days > 0:
        q = q.where(ComplaintRow.created_at >= datetime.now(timezone.utc) - timedelta(days=days))
    if office_id is not None:
        q = q.where(ComplaintRow.office_id == office_id)
    if category_id is not None:
        q = q.where(ComplaintRow.category_id == category_id)
    rows = list(db.scalars(q.order_by(ComplaintRow.created_at.desc())))

    # Office names mapping (matches offices_tbl IDs in this deployment)
    _office_names = {
        1: 'City Engineering Office',
        2: 'City Health Office',
        3: 'City Environment & Natural Resources (CENRO)',
        4: 'City Social Welfare & Development (CSWDO)',
        5: 'City Disaster Risk Reduction (CDRRMO)',
        6: 'City Public Safety Office / Police',
        7: "City Mayor's Office (General Concerns)",
    }
    # Complaint type to category name mapping (using title of each row)
    def _office_label(oid):
        return _office_names.get(oid, f'Office {oid}')

    def _category_label(c):
        # Use the complaint's title as a category grouping fallback
        return c.title.split(' / ')[0].strip() if c.title else f'Category {c.category_id}'

    def tally(fn):
        d = {}
        for c in rows:
            label = fn(c)
            d[label] = d.get(label, 0) + 1
        return [{'label': k, 'count': v} for k, v in sorted(d.items(), key=lambda x: -x[1])]

    closed = sum(c.status in ('resolved', 'closed') for c in rows)
    return ok({
        'total': len(rows),
        'open': len(rows) - closed,
        'resolved': closed,
        'by_category': tally(_category_label),
        'by_office': tally(lambda c: _office_label(c.office_id)),
        'by_priority': tally(lambda c: (c.priority or 'medium').capitalize()),
        'by_status': tally(lambda c: (c.status or 'submitted').replace('_', ' ').title()),
        'rows': [complaint_json(c, db) for c in rows],
    })


@app.get('/api/reports/export-csv')
def export_report_csv(
    days: int = 30,
    month: Optional[str] = None,
    office_id: Optional[int] = None,
    category_id: Optional[int] = None,
    token: Optional[str] = None,
    authorization: Optional[str] = Header(default=None),
    db: Session = Depends(get_db)
):
    """
    Returns a **designed CSV report** with:
      - Report header (title, date range or month, generated by, generated at)
      - Summary section (totals, service level)
      - Breakdown by office and status
      - Full complaints data table
    """
    auth_header = authorization
    if not auth_header and token:
        auth_header = f'Bearer {token.strip()}'
    user = current_user(authorization=auth_header, db=db)
    require_role(user, 'admin')
    import io, csv as csv_mod

    q = select(ComplaintRow)
    if month and len(month) == 7 and '-' in month:
        try:
            yr, mo = map(int, month.split('-'))
            start_dt = datetime(yr, mo, 1, tzinfo=timezone.utc)
            end_dt = datetime(yr + (1 if mo == 12 else 0), 1 if mo == 12 else mo + 1, 1, tzinfo=timezone.utc)
            q = q.where(ComplaintRow.created_at >= start_dt, ComplaintRow.created_at < end_dt)
        except Exception:
            pass
    elif days > 0:
        q = q.where(ComplaintRow.created_at >= datetime.now(timezone.utc) - timedelta(days=days))
    if office_id is not None:
        q = q.where(ComplaintRow.office_id == office_id)
    if category_id is not None:
        q = q.where(ComplaintRow.category_id == category_id)
    rows = list(db.scalars(q.order_by(ComplaintRow.created_at.desc())))

    _office_names = {
        1: 'City Engineering Office',
        2: 'City Health Office',
        3: 'City Environment & Natural Resources (CENRO)',
        4: 'City Social Welfare & Development (CSWDO)',
        5: 'City Disaster Risk Reduction (CDRRMO)',
        6: 'City Public Safety Office / Police',
        7: "City Mayor's Office (General Concerns)",
    }
    def _office_label(oid):
        return _office_names.get(oid, f'Office {oid}')

    total = len(rows)
    resolved = sum(c.status in ('resolved', 'closed') for c in rows)
    pending = sum(c.status in ('submitted', 'received') for c in rows)
    in_progress = sum(c.status == 'in_progress' for c in rows)
    service_level = round(resolved * 100 / total, 1) if total else 0

    period_label = f'Monthly Report ({month})' if month else ('All Time' if days == 0 else f'Last {days} days')
    generated_at = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
    _log_activity(db, user, 'export_report_csv', f'{user.name} exported admin CSV report ({period_label}).', 'report', office_id)

    # Office breakdown
    office_counts = {}
    for c in rows:
        label = _office_label(c.office_id)
        office_counts[label] = office_counts.get(label, 0) + 1

    # Status breakdown
    status_counts = {}
    for c in rows:
        label = (c.status or 'submitted').replace('_', ' ').title()
        status_counts[label] = status_counts.get(label, 0) + 1

    # Build CSV in memory
    output = io.StringIO()
    w = csv_mod.writer(output)

    # ── SECTION 1: Report Header ─────────────────────────────────────────────
    w.writerow(['CABADBARAN CITIZENSENSE — COMPLAINT REPORT'])
    w.writerow(['Barangay Cabadbaran City, Agusan del Norte, Philippines'])
    w.writerow([])
    w.writerow(['Report Period:', period_label])
    w.writerow(['Generated At:', generated_at])
    w.writerow(['Generated By:', f'{user.name} ({user.email})'])
    if office_id:
        w.writerow(['Office Filter:', _office_label(office_id)])
    w.writerow([])

    # ── SECTION 2: Summary ───────────────────────────────────────────────────
    w.writerow(['=== SUMMARY ==='])
    w.writerow(['Metric', 'Value'])
    w.writerow(['Total Complaints', total])
    w.writerow(['Pending (Submitted / Received)', pending])
    w.writerow(['In Progress', in_progress])
    w.writerow(['Resolved / Closed', resolved])
    w.writerow(['Service Level (%)', f'{service_level}%'])
    w.writerow([])

    # ── SECTION 3: Breakdown by Office ──────────────────────────────────────
    w.writerow(['=== BREAKDOWN BY OFFICE ==='])
    w.writerow(['Office', 'Complaints', '% of Total'])
    for name, count in sorted(office_counts.items(), key=lambda x: -x[1]):
        pct = f'{round(count * 100 / total, 1)}%' if total else '0%'
        w.writerow([name, count, pct])
    w.writerow([])

    # ── SECTION 4: Breakdown by Status ──────────────────────────────────────
    w.writerow(['=== BREAKDOWN BY STATUS ==='])
    w.writerow(['Status', 'Complaints', '% of Total'])
    for label, count in sorted(status_counts.items(), key=lambda x: -x[1]):
        pct = f'{round(count * 100 / total, 1)}%' if total else '0%'
        w.writerow([label, count, pct])
    w.writerow([])

    # ── SECTION 5: Complaint Data ────────────────────────────────────────────
    w.writerow(['=== COMPLAINT DATA ==='])
    w.writerow([
        'ID', 'Date Submitted', 'Complaint Type', 'Description (excerpt)',
        'Assigned Office', 'Status', 'Priority', 'Sentiment',
        'Date Resolved', 'Response Message'
    ])
    for c in rows:
        desc_short = (c.description or '').split('\n')[0][:120]
        date_sub = c.created_at.strftime('%Y-%m-%d %H:%M') if c.created_at else ''
        date_res = c.date_resolved.strftime('%Y-%m-%d %H:%M') if c.date_resolved else ''
        w.writerow([
            c.id,
            date_sub,
            c.title or '',
            desc_short,
            _office_label(c.office_id),
            (c.status or '').replace('_', ' ').title(),
            (c.priority or '').capitalize(),
            (c.sentiment or '').capitalize(),
            date_res,
            (c.response_message or '').replace('\n', ' ')[:200],
        ])

    output.seek(0)
    filename = f'CitizenSense_Report_{datetime.now().strftime("%Y%m%d_%H%M")}.csv'
    from fastapi.responses import StreamingResponse
    return StreamingResponse(
        iter([output.getvalue()]),
        media_type='text/csv',
        headers={'Content-Disposition': f'attachment; filename="{filename}"'},
    )

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
def set_active(
    user_id: int,
    data: Optional[AdminUpdateUserIn] = None,
    active: Optional[bool] = None,
    user: User = Depends(current_user),
    db: Session = Depends(get_db),
):
    require_role(user, 'admin')
    target = db.get(User, user_id)
    if not target:
        raise HTTPException(404, detail={'code': 'NOT_FOUND', 'message': 'User not found.', 'details': {}})

    new_active = data.active if (data is not None and data.active is not None) else active
    if new_active is not None:
        if target.id == user.id and not new_active:
            raise HTTPException(409, detail={'code': 'CONFLICT', 'message': 'You cannot deactivate your own account.', 'details': {}})
        target.active = new_active

    if data is not None:
        if data.name is not None:
            target.name = data.name.strip()
        if data.office_id is not None and target.role == 'staff':
            target.office_id = data.office_id
        if data.password is not None:
            target.password_hash = hash_password(data.password)

    if new_active is None and (data is None or (data.name is None and data.office_id is None and data.password is None)):
        raise HTTPException(422, detail={'code': 'VALIDATION_ERROR', 'message': 'No update fields provided.'})

    db.commit()
    db.refresh(target)
    _log_activity(db, user, 'update_user', f'{user.name} updated account for {target.name} ({target.role}).', 'user', target.id)
    return ok({'user': user_json(target), 'message': 'User updated successfully.'})

@app.delete('/api/admin/users/{user_id}')
def delete_staff_user(user_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, 'admin')
    target = db.get(User, user_id)
    if not target:
        raise HTTPException(404, detail={'code': 'NOT_FOUND', 'message': 'User not found.'})
    if target.id == user.id:
        raise HTTPException(409, detail={'code': 'CONFLICT', 'message': 'You cannot delete your own account.'})
    if target.role != 'staff':
        raise HTTPException(403, detail={'code': 'FORBIDDEN', 'message': 'Only staff accounts can be deleted here.'})
    name = target.name
    db.delete(target)
    db.commit()
    _log_activity(db, user, 'delete_staff', f'{user.name} deleted staff account {name}.', 'user', user_id)
    return ok({'message': f'Staff account "{name}" deleted.'})

@app.get('/api/admin/activity-logs')
def get_activity_logs(
    role: Optional[str] = None,
    limit: int = 200,
    user: User = Depends(current_user),
    db: Session = Depends(get_db),
):
    """Admin-only activity log showing what citizens, staff, and admins are doing."""
    require_role(user, 'admin')
    q = select(ActivityLog)
    if role and role in ('citizen', 'staff', 'admin', 'system'):
        q = q.where(ActivityLog.actor_role == role)
    rows = list(db.scalars(q.order_by(ActivityLog.created_at.desc()).limit(min(limit, 500))))
    return ok({'items': [
        {
            'id': r.id,
            'actor_name': r.actor_name,
            'actor_role': r.actor_role,
            'action': r.action,
            'summary': r.summary,
            'target_type': r.target_type,
            'target_id': r.target_id,
            'created_at': iso(r.created_at),
        }
        for r in rows
    ]})

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
    """Return all notifications for the current user within today (UTC+8), newest first."""
    ph_tz = timezone(timedelta(hours=8))
    now_ph = datetime.now(ph_tz)
    start_of_today_utc = now_ph.replace(hour=0, minute=0, second=0, microsecond=0).astimezone(timezone.utc)
    rows = list(db.scalars(
        select(Notification)
        .where(Notification.user_id == user.id, Notification.created_at >= start_of_today_utc)
        .order_by(Notification.created_at.desc())
        .limit(100)
    ))
    items = [
        {
            'id': n.id,
            'text': n.text,
            'type': n.type,
            'complaint_id': n.complaint_id,
            'at': iso(n.created_at),
            'is_read': n.is_read,
        }
        for n in rows
    ]
    return ok({'items': items})

@app.patch('/api/notifications/read')
def mark_notifications_read(user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Mark all of this user's notifications as read."""
    unread = list(db.scalars(
        select(Notification).where(Notification.user_id == user.id, Notification.is_read == False)
    ))
    for n in unread:
        n.is_read = True
    db.commit()
    return ok({'message': f'{len(unread)} notifications marked as read.'})

# ─── Announcements & Promotions ───────────────────────────────────────────────

def _announcement_json(a: Announcement) -> dict:
    return {
        'id': a.id,
        'title': a.title,
        'content': a.content,
        'category': a.category,
        'status': a.status,
        'is_active': a.is_active,
        'created_by_id': a.created_by_id,
        'created_by_name': a.created_by_name,
        'created_by_role': a.created_by_role,
        'reviewed_by_name': a.reviewed_by_name,
        'created_at': iso(a.created_at),
    }

@app.get('/api/announcements/public')
def public_announcements(db: Session = Depends(get_db)):
    """Public endpoint for Login page slideshow & citizen login popup."""
    rows = list(db.scalars(
        select(Announcement)
        .where(Announcement.status == 'approved', Announcement.is_active == True)
        .order_by(Announcement.created_at.desc())
    ))
    return ok({'items': [_announcement_json(a) for a in rows]})

@app.get('/api/announcements')
def list_announcements(user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, 'admin', 'staff')
    q = select(Announcement)
    if user.role == 'staff':
        q = q.where((Announcement.created_by_id == user.id) | (Announcement.status == 'approved'))
    rows = list(db.scalars(q.order_by(Announcement.created_at.desc())))
    return ok({'items': [_announcement_json(a) for a in rows]})

@app.post('/api/announcements')
def create_announcement(data: AnnouncementIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, 'admin', 'staff')
    is_admin = user.role == 'admin'
    ann = Announcement(
        title=data.title.strip(),
        content=data.content.strip(),
        category=data.category.strip() or 'Announcement',
        status='approved' if is_admin else 'pending',
        is_active=True,
        created_by_id=user.id,
        created_by_name=user.name,
        created_by_role=user.role,
        reviewed_by_name=user.name if is_admin else None,
    )
    db.add(ann)
    db.commit()
    db.refresh(ann)

    if not is_admin:
        admins = list(db.scalars(select(User).where(User.role == 'admin', User.active == True)))
        for adm in admins:
            _push_notification(
                db, adm.id, None, 'announcement_request',
                f'Staff {user.name} requested an announcement: "{ann.title[:60]}"'
            )
        db.commit()
        _log_activity(db, user, 'request_announcement', f'{user.name} requested announcement "{ann.title}".', 'announcement', ann.id)
    else:
        _log_activity(db, user, 'create_announcement', f'{user.name} published announcement "{ann.title}".', 'announcement', ann.id)

    return ok({'item': _announcement_json(ann), 'message': 'Published!' if is_admin else 'Request sent to Admin for approval.'})

@app.patch('/api/announcements/{ann_id}')
def update_announcement(ann_id: int, data: AnnouncementUpdateIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, 'admin')
    ann = db.get(Announcement, ann_id)
    if not ann:
        raise HTTPException(404, detail={'code': 'NOT_FOUND', 'message': 'Announcement not found.'})

    old_status = ann.status
    if data.title is not None: ann.title = data.title.strip()
    if data.content is not None: ann.content = data.content.strip()
    if data.category is not None: ann.category = data.category.strip()
    if data.is_active is not None: ann.is_active = data.is_active
    if data.status is not None and data.status in ('approved', 'rejected', 'pending'):
        ann.status = data.status
        ann.reviewed_by_name = user.name

    db.commit()
    db.refresh(ann)

    if data.status and data.status != old_status and ann.created_by_role == 'staff':
        _push_notification(
            db, ann.created_by_id, None, 'announcement_review',
            f'Your announcement request "{ann.title[:50]}" was {ann.status} by {user.name}.'
        )
        db.commit()

    _log_activity(db, user, 'update_announcement', f'{user.name} updated announcement #{ann.id} ({ann.status}).', 'announcement', ann.id)
    return ok({'item': _announcement_json(ann)})

@app.delete('/api/announcements/{ann_id}')
def delete_announcement(ann_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, 'admin', 'staff')
    ann = db.get(Announcement, ann_id)
    if not ann:
        raise HTTPException(404, detail={'code': 'NOT_FOUND', 'message': 'Announcement not found.'})
    if user.role == 'staff' and (ann.created_by_id != user.id or ann.status != 'pending'):
        raise HTTPException(403, detail={'code': 'FORBIDDEN', 'message': 'You can only delete your own pending requests.'})
    db.delete(ann)
    db.commit()
    _log_activity(db, user, 'delete_announcement', f'{user.name} deleted announcement #{ann_id}.', 'announcement', ann_id)
    return ok({'message': 'Announcement deleted.'})

