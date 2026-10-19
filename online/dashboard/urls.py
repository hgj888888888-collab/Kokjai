# -*- coding: utf-8 -*-
from django.urls import path

from . import views

urlpatterns = [
    path("", views.index, name="index"),
    path("api/dashboard/", views.dashboard, name="api-dashboard"),
    path("api/orders/", views.orders, name="api-orders"),
    path("api/tickets/", views.tickets, name="api-tickets"),
    path("api/tickets/<str:ticket_id>/handle/", views.handle_ticket, name="api-ticket-handle"),
    path("api/handle-stats/", views.handle_stats, name="api-handle-stats"),
    path("api/predict/", views.predict, name="api-predict"),
]
